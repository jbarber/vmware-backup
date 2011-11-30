h1. NAME

clone-and-delete-vms - Backup VMs via cloning and delete the clones when they are old

h1. SYNTAX

.\clone-and-delete-vms.ps1 -config .\clone-and-delete-vms.xml [-verbose ] [-dryrun] [-nodelete] [-nobackup] [-server 127.0.0.1] [-username vmbackup] [-password sekret] [-retention 6] [-targetfolder BACKUP]

h1. DESCRIPTION

This is a powershell script for backing up guests (Virtual Machines) under a VMware vSphere environment. It's configured using an XML file which specifies which guests to backup on which hosts/clusters and where to store the backups.

The clones are created with the same name as the original with the suffix '-backup-YYYY-MM-DDTHH:MM' apended. They are created in datastores, compute resources, and folders of choice.

Backups are taken by cloning the guests and are deleted when the age of the backup (as encoded in the name of the VM backup name) is greater than the retention period.

h1. LIMITATIONS

The backups are taken by cloning the guests, which requires snapshoting them. This mechanism will therefore *not* work with guests that have storage which is not snapshotable (such as persistant RDMs). Note this limitation applies to other backup methods such as VMwares VCB and VDR.

Currently only a single retention period can be specfied. This limitation can be overcome by using multiple invocations to backup guests with different retention requirements.

h1. LICENSE

Copyright (c) 2011, Jonathan Barber
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
