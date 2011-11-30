<#  
.SYNOPSIS  
  Backups VMware VMs by cloning them
.DESCRIPTION

Script to clone VMs to new VM with suffix -backup-YYYY-MM-DDTHH:MM. It will not take a backup if an older backup exists which is less that $backupPeriod days

Backups older than $backupPeriod are deleted - after the backup is taken.

Backups created during this scripts execution are not deleted during the same run of the script.

.NOTES 

The configuration file is an XML file with the following structure:
  <clone-and-delete-vms>
    <server>my-vc-server</server>
    <username>vmbackup</username>
    <password>sekret</password>
    <backupPeriod>6</backupPeriod>
    <targetFolder>BACKUP</targetFolder>
  
    <targetBackups>
      <target>
        <name>host1</name>
        <datastore>DATASTORE2</datastore>
        <cluster>Cluster 2</cluster>
      </target>
        <name>host2</name>
        <datastore>DATASTORE1</datastore>
        <cluster>Cluster 1</cluster>
      </target>
    </targetBackups>
  </clone-and-delete-vms>

The author is Jonathan Barber <jonathan.barber@gmail.com>.

.PARAMETER server
  VMware Virtual Center machine to connect to. Defaults to 127.0.0.1
.PARAMETER username
  Username to connect to Virtual Center with. Defaults to vmbackup
.PARAMETER password
  Password to use to connect to Virtual Center. No default value.
.PARAMETER backupPeriod
  Minimum number of days between which VM should be backed up. Defaults to 6.
.PARAMETER targetFolder
  Folder that VMs are cloned to. Defaults to BACKUP
.PARAMETER config
  Path to configuration XML file. Defaults to "clone-and-delete-vms.xml"
#>

Param(
  [string]$server = "127.0.0.1",
  [string]$username = "vmbackup",
  [string]$password,
  [int]$backupPeriod = 6,
  [string]$targetFolder = "BACKUP",
  [string]$config = "clone-and-delete-vms.xml"
)

# Read the config
if (Test-path $config) {
  $xml = ([xml](get-content $config)).FirstChild
  $server = $xml.server
  $username = $xml.username
  $password = $xml.password
  $backupPeriod = $xml.backupPeriod

  $targetBackups = @{}
  $xml.targetBackups.target | %{ 
    $targetBackups.Add( $_.name, $_ ) }
}

# check options are set after reading config
if (! $server) {
  write-error "server option not set, required"
  exit 1
}

if (! $username) {
  write-error "username option not set, required"
  exit 1
}

if (! $password) {
  write-error "password option not set, required"
  exit 1
}

Add-PSSnapin Vmware*
$ErrorActionPreference = "Stop"
Connect-VIserver -server $server -username $username -password $password

$evt = New-Object System.Diagnostics.EventLog("Application")
$evt.Source = $MyInvocation.MyCommand.Name

$evt.WriteEntry("Starting script")

function Clone-VM (
  [parameter(Mandatory = $true)][string]$sourceVM,
  [parameter(Mandatory = $true)][string]$targetVM,
  [string]$targetFolderName,
  [string]$targetDatastore,
  [switch]$sparse,
  [string]$targetCluster) {
<#
.SYNOPSIS
  This function will clone a Virtual Machine from an existing VM.
.PARAMETER -sourceVM
  The name of the VM you want to clone.
.PARAMETER -targetVM
  The name of the VM you want to create. Defaults to "root folder".
.PARAMETER -targetFolderName
  The name of the folder the new VM should be created under.
.PARAMETER -targetDatastore
  The name of the datastore the new VM should be created on.
.PARAMETER -targetCluster
  The name of the cluster the new VM should be created on.

#>
  if ( $targetFolderName ) { 
    $folder = Get-Folder -Name $targetFolderName -erroraction stop
    $targetFolder = Get-View $folder.ID
  }
  else  {
    $targetFolder = Get-View ( Get-Folder -Name vm ).ID  
    $targetFolderName = "root folder"
  }

  $VMCloneSpec = New-Object VMware.Vim.VirtualMachineCloneSpec
  $VMCloneSpec.Location = New-Object VMware.Vim.VirtualMachineRelocateSpec
  $VMCloneSpec.powerOn = $false

  if ( $targetDatastore ) {
    $VMCloneSpec.Location.Datastore = (Get-View (Get-Datastore -Name $targetDatastore -erroraction stop).ID ).MoRef
  }

  if ( $targetCluster ) {
    $cluster = (Get-View -viewtype ClusterComputeResource -Filter @{ Name = $targetCluster })
    $VMCloneSpec.Location.Host = $cluster.Host[0]
    $VMCloneSpec.Location.Pool = $cluster.ResourcePool
  }

  if ( $sparse ) {
    $VMCloneSpec.Location.Transform = [VMware.Vim.VirtualMachineRelocateTransformation]::sparse
  }
  
  Write-verbose "Cloning $sourceVM to $targetVM in folder $targetFolderName"
  (Get-View ( Get-VM -Name $sourceVM).ID).CloneVM_Task($targetFolder.MoRef, $targetVM, $VMCloneSpec)
}

# Match $VMname with $regex, and return how long ago the backup was made
function backupAge ([string]$VMname, [string]$regex) {
  if ($VMname -match $regex) {
    return ((get-date) - (get-date -date $matches[2]))
  }
  else {
    throw "VMname ($VMname) isn't matched by regex ($regex)"
  }
}

# Regex to find backup clones and extract their base VM name and when they were created
$backupMatch = '(.*)-backup-(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})$'

# Clone VMs that aren't a backup in their name and that have backups older than $backupPeriod
$vms = get-vm
$vms | %{ $_.name } | ?{ -not ($_ -match $backupMatch) } | ?{ $targetBackups.containsKey( $_ ) } | %{
  # This date format *must* match $backupMatch - otherwise you'll never delete old backups
  $date = get-date -uformat %Y-%m-%dT%R
  $src = $_
  $target = $src, "backup", $date -join "-"
  $targetStore = $targetBackups[$src].datastore
  $targetCluster = $targetBackups[$src].cluster

  # Check if the $src has a backup
  $backup = $false
  if ( $backups = ($vms | %{ $_.name } | ?{ ($_ -like "$src-*") -and ($_ -match $backupMatch) }) ) {
    write-verbose "$src has backups"
    $evt.WriteEntry( "$src has backups" )
    # If $src does have a backup, see if the backup is older than $backupPeriod
    if ( $backups | ?{ ((backupAge -VMname $_ -regex $backupMatch).Days -ge $backupPeriod) } ) {
      $backup = $true
      write-verbose "$src backups are stale"
      $evt.WriteEntry( "$src backups are stale" )
    }
    else {
      write-verbose "$src backups are fresh"
      $evt.WriteEntry( "$src backups are fresh" )
    }
  }
  else {
    $backup = $true
    write-verbose "$src doesn't have backups"
    $evt.WriteEntry( "$src doesn't have backups" )
  }
 
  if ($backup) {
    write-verbose "Taking backup of $src"
    $evt.WriteEntry( "Taking backup of $src" )
    wait-task (get-viobjectbyviview (Clone-VM -sourceVM $src -targetVM $target -targetDatastore $targetStore -targetFolderName $targetFolder -sparse -targetCluster $targetCluster))
  }
}

# Look for old backups and delete them
$vms | ?{ $_.name -match $backupMatch } | %{ $_.name } | %{
  if ( (backupAge -VMname $_ -regex $backupMatch ).Days -ge $backupPeriod ) {
    write-verbose "Deleting $_"
    $evt.WriteEntry( "Deleting $_" )
    remove-vm -deletefromdisk -runasync -confirm:$false -vm $_
  }
}
