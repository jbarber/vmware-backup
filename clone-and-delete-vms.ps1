<#  
.SYNOPSIS  
  Backups VMware VMs by cloning them
.DESCRIPTION

Script to clone VMs to new VM with suffix -backup-YYYY-MM-DDTHH:MM.

Backups older than $retention are deleted - after the backup is taken.

Backups created during this scripts execution are not deleted during the same run of the script.

.NOTES 

The configuration file is an XML file with the following structure:
  <clone-and-delete-vms>
    <server>my-vc-server</server>
    <username>vmbackup</username>
    <password>sekret</password>
    <retention>6</retention>
    <targetFolder>BACKUP</targetFolder>
  
    <targetBackups>
      <target>
        <name>host1</name>
        <datastore>DATASTORE2</datastore>
        <cluster>Cluster 2</cluster>
      </target>
      <target>
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
.PARAMETER retention
  Minimum number of days between which VM should be backed up. Defaults to 6.
.PARAMETER targetFolder
  Folder that VMs are cloned to. Defaults to BACKUP
.PARAMETER config
  Path to configuration XML file. Defaults to "clone-and-delete-vms.xml"
.PARAMETER verbose
  Switch for more logging
.PARAMETER dryrun
  Switch to disable taking backups and deleting old backups 
.PARAMETER nobackup
  Disable taking backups
.PARAMETER nodelete
  Disable deleting old backups
#>

Param(
  [string]$server = "127.0.0.1",
  [string]$username = "vmbackup",
  [string]$password,
  [int]$retention = 6,
  [string]$targetFolder = "BACKUP",
  [string]$config = "clone-and-delete-vms.xml",
  [switch]$verbose = $False,
  [switch]$dryrun = $False,
  [switch]$nobackup = $False,
  [switch]$nodelete = $False
)

# Read the config
if (Test-path $config) {
  $doc = [xml](get-content $config)
  $xml = $doc.FirstChild
  if ($xml.server    -ne $null) { $server = $xml.server }
  if ($xml.username  -ne $null) { $username = $xml.username }
  if ($xml.password  -ne $null) { $password = $xml.password }
  if ($xml.retention -ne $null) { $retention = $xml.retention }
  if ($xml.targetFolder -ne $null) { $targetFolder = $xml.targetFolder }

  $new_retention = $doc.CreateElement("retention")
  [void]$new_retention.set_InnerXML($retention)

  $targetBackups = @{}
  $xml.targetBackups.target | %{ 
    if (-not $_.retention) {
      [void]$_.AppendChild($new_retention)
    }
    [void]$targetBackups.Add( $_.name, $_ )
  }
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

if ($verbose) {
  $VerbosePreference = "Continue"
}

# Only load a Snappin if it's not already registered
function addSnappin (
  [parameter(Mandatory = $true)][string]$snappin
) {
  if (-not (get-pssnapin | ?{ $_.name -eq $snappin })) {
    Add-PSSnapin $snappin
  }
}

$evt = New-Object System.Diagnostics.EventLog("Application")
$evt.Source = $MyInvocation.MyCommand.Name
function evtLog {
  try {
    $evt.WriteEntry( $args )
  }
  catch {
  }
}

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
  
  write-verbose "Cloning $sourceVM to $targetVM in folder $targetFolderName"
  return (Get-View (Get-VM -Name $sourceVM).ID).CloneVM_Task($targetFolder.MoRef, $targetVM, $VMCloneSpec)
}

# Match $VMname with $regex and return how long ago the backup was made
function backupAge (
  [string]$VMname,
  [string]$regex
) {
  if ($VMname -match $regex) {
    return ((get-date) - (get-date -date $matches[2]))
  }
  else {
    throw "VMname ($VMname) isn't matched by regex ($regex)"
  }
}

# Return whether the VM was backed up more than $age days ago
function backupOld (
  [string]$VMname,
  [string]$regex,
  [int]$age
) {
    return (backupAge -VMname $VMname -regex $regex).Days -ge $age
}

function backupVMs (
  [array]$vms,
  [string]$backupMatch,
  [int]$retention,
  [string]$dateFormat,
  $targetBackups
) {
  $targets = $vms | %{ $_.name } | ?{ -not ($_ -match $backupMatch) } | ?{ $targetBackups.containsKey( $_ ) } 

  foreach ($src in $targets) {
    $date = get-date -uformat $dateFormat
    $target = ($src, "backup", $date) -join "-"
    $targetStore = $targetBackups[$src].datastore
    $targetCluster = $targetBackups[$src].cluster

    # Check if the $src has a backup
    $backup = $false
#    if ( $backups = ($vms | %{ $_.name } | ?{ ($_ -like "$src-*") -and ($_ -match $backupMatch) }) ) {
#      write-verbose "$src has backups"
##      $evt.WriteEntry( "$src has backups" )
#      # See if any of the backups are old
#      if ( $backups | ?{ backupOld $_ $backupMatch $retention } ) {
#        $backup = $true
#        write-verbose "$src backups are stale"
##        $evt.WriteEntry( "$src backups are stale" )
#      }
#      else {
#        write-verbose "$src backups are fresh"
##        $evt.WriteEntry( "$src backups are fresh" )
#      }
#    }
#    else {
#      $backup = $true
#      write-verbose "$src doesn't have backups"
##      $evt.WriteEntry( "$src doesn't have backups" )
#    }
 
    $backup = $true
    if ($backup) {
      write-verbose "Taking backup of $src"
      evtLog "Taking backup of $src"
      if ($dryrun) {
        write-verbose "In dryrun mode, not cloning"
      }
      else {
        try {
          wait-task (get-viobjectbyviview (Clone-VM -sourceVM $src -targetVM $target -targetDatastore $targetStore -targetFolderName $targetFolder -sparse -targetCluster $targetCluster))
        }
        catch {
          evtLog ("Cloning $vm failed: " + $_.Exception.Message)
          write-verbose ("Cloning $vm failed: " + $_.Exception.Message)
        }
      }
    }
  }
}

# Look for old backups and delete them
function deleteOldBackups (
  [array]$vms,
  [string]$backupMatch,
  [int]$retention,
  $targetBackups
) {
  write-verbose "Looking for old backups:"
  $candidates = $vms | ?{ $_.name -match $backupMatch } | %{ $_.name } 

  foreach ($vm in $candidates) {
    write-verbose "  VM found: $vm"

    $targets = $targetBackups.getEnumerator() | ?{ $vm -like ($_.name + "-*") }
    if (-not $targets) {
      write-verbose "  - not found in targetBackups, ignoring"
      continue
    }
    if ($targets.count -gt 1) {
      write-verbose "  - name matches more than one target!"
    }

    # TODO: Select one element from $targets and use the retention time from
    # that element
    #$target = $targets[0].value
    #write-verbose ("  - VM age is " + (backupAge -VMname $vm -regex $backupMatch))

    if (backupOld $vm $backupMatch $retention) {
      write-verbose "  - older than $retention, deleting"
      evtLog "Deleting $vm"
      if ($dryrun) {
        write-verbose "  - In dryrun mode, not deleting"
      }
      else {
        try {
          remove-vm -deletefromdisk -runasync -confirm:$false -vm $vm
        }
        catch {
          evtLog ("Delting $vm failed: " + $_.Exception.Message)
          write-verbose ("  - deletion failed: " + $_.Exception.Message)
        }
      }
    }
    else {
      write-verbose "  - younger than $retention, keeping"
    }
  }
}

# Regex to find backup clones and extract their base VM name and when they were created
$backupMatch = '(.*)-backup-(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})$'
# This date format is used to name the backups, and it *must* match
# $backupMatch - otherwise you'll never delete old backups
$dateFormat  = '%Y-%m-%dT%R'
$ErrorActionPreference = "Stop"

evtLog "Starting script"
addSnappin 'VMware.VimAutomation.Core'
Connect-VIserver -server $server -username $username -password $password

# Clone VMs that aren't a backup in their name and that have backups older than $retention
$vms = get-vm
if (-not $nobackup) {
  backupVMs $vms $backupMatch $retention $dateFormat $targetBackups
}
if (-not $nodelete) {
  deleteOldBackups $vms $backupMatch $retention $targetBackups
}
evtLog "Stopping script"
disconnect-viserver -force -server * -confirm:$false
