#Requires -Modules Posh-SSH
param([string]$LogPath = "C:\Scripts\MariaDB-Staging\Logs")

$Config = @{
    ESXiHost = "a.b.c.d"
    StagingIP = "a.b.c.d"
    MySQLDataPath = "/var/lib/mysql"
    MountPoint = "/mnt/replica-disk"
    CredentialPath = "C:\Scripts\MariaDB-Staging"
    ReplicaVGName = "VolGroup_replica"
}

$LogFile = Join-Path $LogPath "sync-$(Get-Date -Format 'yyyy-MM-dd-HHmmss').log"
if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $lm = "[$ts] [$Level] $Message"
    Add-Content -Path $LogFile -Value $lm
    switch ($Level) {
        "ERROR" { Write-Host $lm -ForegroundColor Red }
        "WARNING" { Write-Host $lm -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $lm -ForegroundColor Green }
        default { Write-Host $lm }
    }
}

function Invoke-SSHCmd {
    param([object]$Session, [string]$Command, [string]$Description, [switch]$IgnoreError, [int]$TimeOut = 300)
    Write-Log "[$Description] $Command"
    $result = Invoke-SSHCommand -SessionId $Session.SessionId -Command $Command -TimeOut $TimeOut
    if ($result.ExitStatus -ne 0 -and -not $IgnoreError) {
        Write-Log "Exit $($result.ExitStatus): $($result.Error)" "WARNING"
    }
    if ($result.Output) { $result.Output | ForEach-Object { Write-Log "  $_" } }
    return $result
}

$ErrorActionPreference = "Stop"
$vmDiskAdded = $false
$esxiSession = $null
$linuxSession = $null
$stagingVMID = $null
$vmdkFullPath = $null
$diskUnitNumber = $null
$actualVGName = $null

try {
    Write-Log "========== Starting MariaDB Staging Sync =========="
    $esxiCred = Import-Clixml -Path (Join-Path $Config.CredentialPath "esxi-cred.xml")
    $linuxCred = Import-Clixml -Path (Join-Path $Config.CredentialPath "linux-cred.xml")

    Write-Log "Connecting to ESXi..."
    $esxiSession = New-SSHSession -ComputerName $Config.ESXiHost -Credential $esxiCred -AcceptKey -Force -ConnectionTimeout 30
    if (-not $esxiSession.Connected) { throw "Failed to connect to ESXi" }
    Write-Log "ESXi connected" "SUCCESS"

    $vmList = Invoke-SSHCmd -Session $esxiSession -Command "vim-cmd vmsvc/getallvms" -Description "List VMs"
    $replicaVMID = $null
    $stagingVMID = $null
    foreach ($line in $vmList.Output) {
        if ($line -match "^\s*(\d+)\s+(.+?)\s+\[") {
            $vmId = $matches[1]
            $vmName = $matches[2].Trim()
            if ($vmName -match "[vmname]].*replica") { $replicaVMID = $vmId }
            if ($vmName -imatch "Staging") { $stagingVMID = $vmId }
        }
    }
    if (-not $replicaVMID) { throw "Replica VM not found" }
    if (-not $stagingVMID) { throw "Staging VM not found" }
    Write-Log "Replica ID: $replicaVMID, Staging ID: $stagingVMID" "SUCCESS"

    $repPower = Invoke-SSHCmd -Session $esxiSession -Command "vim-cmd vmsvc/power.getstate $replicaVMID" -Description "Replica power"
    $stgPower = Invoke-SSHCmd -Session $esxiSession -Command "vim-cmd vmsvc/power.getstate $stagingVMID" -Description "Staging power"
    if (($repPower.Output | Out-String) -notmatch "Powered off") { throw "Replica must be off" }
    if (($stgPower.Output | Out-String) -notmatch "Powered on") { throw "Staging must be on" }
    Write-Log "Power states OK" "SUCCESS"

    Write-Log "Getting VMDK path..."
    $devCmd = "vim-cmd vmsvc/device.getdevices $replicaVMID | grep fileName | head -1"
    $devResult = Invoke-SSHCmd -Session $esxiSession -Command $devCmd -Description "Get VMDK"
    foreach ($line in $devResult.Output) {
        if ($line -match 'fileName\s*=\s*"\[([^\]]+)\]\s*([^"]+)"') {
            $ds = $matches[1]
            $relPath = $matches[2]
            $vmdkFullPath = "/vmfs/volumes/$ds/$relPath"
            break
        }
    }
    if (-not $vmdkFullPath) { throw "Could not get VMDK path" }
    Write-Log "VMDK: $vmdkFullPath" "SUCCESS"

    Write-Log "Attaching VMDK..."
    # Try unit 1 first, then unit 2 if that fails
    $addCmd = "vim-cmd vmsvc/device.diskaddexisting $stagingVMID `"$vmdkFullPath`" 0 1"
    $addResult = Invoke-SSHCmd -Session $esxiSession -Command $addCmd -Description "Add disk"
    if ($addResult.ExitStatus -eq 0) {
        $diskUnitNumber = 1
    } else {
        $addCmd2 = "vim-cmd vmsvc/device.diskaddexisting $stagingVMID `"$vmdkFullPath`" 0 2"
        $addResult = Invoke-SSHCmd -Session $esxiSession -Command $addCmd2 -Description "Add disk unit 2"
        if ($addResult.ExitStatus -eq 0) {
            $diskUnitNumber = 2
        }
    }
    if ($addResult.ExitStatus -ne 0) { throw "Failed to attach VMDK" }
    $vmDiskAdded = $true
    Write-Log "VMDK attached at SCSI 0:$diskUnitNumber" "SUCCESS"
    Start-Sleep -Seconds 5

    Write-Log "Connecting to staging..."
    $linuxSession = New-SSHSession -ComputerName $Config.StagingIP -Credential $linuxCred -AcceptKey -Force -ConnectionTimeout 30
    if (-not $linuxSession.Connected) { throw "Failed to connect to staging" }
    Write-Log "Staging connected" "SUCCESS"

    $scanCmd = "for h in /sys/class/scsi_host/host*; do echo '- - -' | sudo tee `$h/scan >/dev/null; done"
    Invoke-SSHCmd -Session $linuxSession -Command $scanCmd -Description "SCSI rescan" -IgnoreError
    Start-Sleep -Seconds 5
    Invoke-SSHCmd -Session $linuxSession -Command "sudo partprobe 2>/dev/null || true" -Description "Partprobe" -IgnoreError
    Start-Sleep -Seconds 3

    # Find the new disk - escape $ for PowerShell
    $diskResult = Invoke-SSHCmd -Session $linuxSession -Command 'lsblk -ndo NAME | grep -E "^sd[b-z]$" | head -1' -Description "Find disk"
    $newDisk = "sdb"
    foreach ($d in $diskResult.Output) { if ($d -match "^sd[b-z]$") { $newDisk = $d.Trim(); break } }
    Write-Log "New disk: /dev/$newDisk"

    # Use device filter to force LVM to see only the new disk (bypass duplicate UUID detection)
    $lvmFilter = "devices { filter = [""a|/dev/${newDisk}.*|"", ""r|.*|""] } global { use_lvmetad = 0 }"
    $lvmConfig = "--config '$lvmFilter'"

    # Clear LVM cache
    Invoke-SSHCmd -Session $linuxSession -Command "sudo pvscan --cache 2>/dev/null || true" -Description "Clear PV cache" -IgnoreError
    Start-Sleep -Seconds 2

    # Find LVM partition on the new disk using filter
    $pvCmd = "sudo pvs $lvmConfig --noheadings -o pv_name 2>/dev/null | tr -d ' ' | head -1"
    $pvResult = Invoke-SSHCmd -Session $linuxSession -Command $pvCmd -Description "Find PV"
    $pvPart = ""
    foreach ($p in $pvResult.Output) { if ($p -match "/dev/${newDisk}") { $pvPart = $p.Trim(); break } }

    # If no PV found, try common partition numbers
    if (-not $pvPart) {
        Write-Log "PV not found via pvs, trying partition scan..."
        foreach ($partNum in @(5, 2, 3, 1)) {
            $testPart = "/dev/${newDisk}${partNum}"
            $testCmd = "sudo pvs $lvmConfig $testPart 2>/dev/null"
            $testResult = Invoke-SSHCmd -Session $linuxSession -Command $testCmd -Description "Test $testPart" -IgnoreError
            if ($testResult.ExitStatus -eq 0) {
                $pvPart = $testPart
                break
            }
        }
    }
    if (-not $pvPart) { $pvPart = "/dev/${newDisk}5" }
    Write-Log "PV: $pvPart"

    # Clean up any existing replica VG from previous runs
    $cleanupCmd = "sudo vgchange -an $($Config.ReplicaVGName) 2>/dev/null; sudo vgremove -f $($Config.ReplicaVGName) 2>/dev/null; true"
    Invoke-SSHCmd -Session $linuxSession -Command $cleanupCmd -Description "Cleanup old VG" -IgnoreError
    # Also clean up numbered variants
    $cleanupCmd2 = "for i in 1 2 3 4 5; do sudo vgchange -an $($Config.ReplicaVGName)`$i 2>/dev/null; sudo vgremove -f $($Config.ReplicaVGName)`$i 2>/dev/null; done; true"
    Invoke-SSHCmd -Session $linuxSession -Command $cleanupCmd2 -Description "Cleanup numbered VGs" -IgnoreError
    Start-Sleep -Seconds 2

    # Import the VG with device filter - this forces LVM to see the duplicate disk
    $importCmd = "sudo vgimportclone $lvmConfig -n $($Config.ReplicaVGName) $pvPart 2>&1"
    $importResult = Invoke-SSHCmd -Session $linuxSession -Command $importCmd -Description "Import VG"
    Start-Sleep -Seconds 2

    # Rescan after import (without filter now, since UUIDs should be changed)
    Invoke-SSHCmd -Session $linuxSession -Command "sudo pvscan --cache 2>/dev/null || true" -Description "Rescan PVs" -IgnoreError
    Start-Sleep -Seconds 2

    # Find the actual VG name (might have numeric suffix if cleanup failed)
    $vgFindCmd = "sudo vgs --noheadings -o vg_name 2>/dev/null | grep '$($Config.ReplicaVGName)' | head -1 | tr -d ' '"
    $vgFindResult = Invoke-SSHCmd -Session $linuxSession -Command $vgFindCmd -Description "Find replica VG"
    $script:actualVGName = $Config.ReplicaVGName
    foreach ($v in $vgFindResult.Output) { if ($v -match "$($Config.ReplicaVGName)") { $script:actualVGName = $v.Trim(); break } }
    Write-Log "Actual VG name: $actualVGName"

    # Activate the VG
    Invoke-SSHCmd -Session $linuxSession -Command "sudo vgchange -ay $actualVGName 2>/dev/null || true" -Description "Activate VG" -IgnoreError
    Start-Sleep -Seconds 2

    # Find the root LV
    $lvCmd = "sudo lvs --noheadings -o lv_name $actualVGName 2>/dev/null | grep -i root | head -1 | tr -d ' '"
    $lvResult = Invoke-SSHCmd -Session $linuxSession -Command $lvCmd -Description "Find LV"
    $lvName = "lv_root"
    foreach ($l in $lvResult.Output) { if ($l -match "\S+") { $lvName = $l.Trim(); break } }
    $replicaLV = "/dev/$actualVGName/$lvName"
    Write-Log "LV: $replicaLV"

    # Verify the LV exists before mounting
    $lvCheckCmd = "sudo lvs $replicaLV 2>/dev/null"
    $lvCheck = Invoke-SSHCmd -Session $linuxSession -Command $lvCheckCmd -Description "Verify LV" -IgnoreError
    if ($lvCheck.ExitStatus -ne 0) {
        Write-Log "LV not found, checking for imported VGs..."
        $vgListCmd = "sudo vgs --noheadings -o vg_name 2>/dev/null"
        Invoke-SSHCmd -Session $linuxSession -Command $vgListCmd -Description "List VGs"
        throw "Could not find or activate replica volume group"
    }

    Invoke-SSHCmd -Session $linuxSession -Command "sudo mkdir -p $($Config.MountPoint)" -Description "Create mount"
    # Use nouuid for XFS filesystems (XFS won't mount duplicate UUIDs without it)
    $mountResult = Invoke-SSHCmd -Session $linuxSession -Command "sudo mount -o ro,nouuid $replicaLV $($Config.MountPoint)" -Description "Mount"
    if ($mountResult.ExitStatus -ne 0) {
        # Try without nouuid in case it's ext4
        Write-Log "Mount with nouuid failed, trying without..."
        $mountResult = Invoke-SSHCmd -Session $linuxSession -Command "sudo mount -o ro $replicaLV $($Config.MountPoint)" -Description "Mount ext4"
    }
    if ($mountResult.ExitStatus -ne 0) { throw "Mount failed" }
    Write-Log "Mounted" "SUCCESS"

    $verifyCmd = "ls $($Config.MountPoint)$($Config.MySQLDataPath)/ | head -3"
    $verifyResult = Invoke-SSHCmd -Session $linuxSession -Command $verifyCmd -Description "Verify"
    if (-not $verifyResult.Output) { throw "MySQL data not found" }

    $stopCmd = "sudo systemctl stop mariadb 2>/dev/null || sudo systemctl stop mysql 2>/dev/null || true"
    Invoke-SSHCmd -Session $linuxSession -Command $stopCmd -Description "Stop MariaDB"
    Start-Sleep -Seconds 3

    Write-Log "Syncing data..."
    $src = "$($Config.MountPoint)$($Config.MySQLDataPath)/"
    $dst = "$($Config.MySQLDataPath)/"
    # Use -a (archive) without -v (verbose) for faster sync, 1 hour timeout for large databases
    $rsyncCmd = "sudo rsync -a --delete --exclude='*.pid' --exclude='*.sock' --exclude='*.err' $src $dst"
    $rsyncResult = Invoke-SSHCmd -Session $linuxSession -Command $rsyncCmd -Description "Rsync" -TimeOut 3600
    if ($rsyncResult.ExitStatus -ne 0) { throw "Rsync failed" }
    Write-Log "Synced" "SUCCESS"

    Invoke-SSHCmd -Session $linuxSession -Command "sudo chown -R mysql:mysql $($Config.MySQLDataPath)" -Description "Chown"
    $startCmd = "sudo systemctl start mariadb 2>/dev/null || sudo systemctl start mysql"
    Invoke-SSHCmd -Session $linuxSession -Command $startCmd -Description "Start MariaDB"
    Start-Sleep -Seconds 5

    $statusCmd = "systemctl is-active mariadb 2>/dev/null || systemctl is-active mysql"
    $statusResult = Invoke-SSHCmd -Session $linuxSession -Command $statusCmd -Description "Status"
    if ($statusResult.Output -match "active") {
        Write-Log "MariaDB running" "SUCCESS"
    } else {
        Write-Log "Check MariaDB manually" "WARNING"
    }

    Invoke-SSHCmd -Session $linuxSession -Command "sudo umount $($Config.MountPoint) 2>/dev/null || true" -Description "Unmount" -IgnoreError
    # Deactivate and remove the replica VG (use actual name if found, otherwise try base name and numbered variants)
    $vgToClean = if ($actualVGName) { $actualVGName } else { $Config.ReplicaVGName }
    Invoke-SSHCmd -Session $linuxSession -Command "sudo vgchange -an $vgToClean 2>/dev/null || true" -Description "Deactivate VG" -IgnoreError
    Invoke-SSHCmd -Session $linuxSession -Command "sudo vgremove -f $vgToClean 2>/dev/null || true" -Description "Remove VG" -IgnoreError
    # Also clean up any numbered variants
    $cleanupAllCmd = "for vg in `$(sudo vgs --noheadings -o vg_name 2>/dev/null | grep '$($Config.ReplicaVGName)'); do sudo vgchange -an `$vg 2>/dev/null; sudo vgremove -f `$vg 2>/dev/null; done; true"
    Invoke-SSHCmd -Session $linuxSession -Command $cleanupAllCmd -Description "Cleanup all replica VGs" -IgnoreError
    Invoke-SSHCmd -Session $linuxSession -Command "sudo pvscan --cache 2>/dev/null || true" -Description "Refresh PV cache" -IgnoreError

    Write-Log "========== Sync completed! ==========" "SUCCESS"

} catch {
    Write-Log "ERROR: $($_.Exception.Message)" "ERROR"
    Write-Log $_.ScriptStackTrace "ERROR"
}
finally {
    if ($vmDiskAdded -and $esxiSession -and $stagingVMID -and $diskUnitNumber) {
        Write-Log "Detaching VMDK..."
        try {
            # Correct syntax: device.diskremove vmid controller_number unit_number delete_file
            # controller_number = 0 (SCSI controller 0)
            # unit_number = the unit we attached to (1 or 2)
            # delete_file = 0 (don't delete the VMDK file)
            $removeCmd = "vim-cmd vmsvc/device.diskremove $stagingVMID 0 $diskUnitNumber 0"
            $removeResult = Invoke-SSHCmd -Session $esxiSession -Command $removeCmd -Description "Remove disk" -IgnoreError
            if ($removeResult.ExitStatus -eq 0) {
                Write-Log "Detached" "SUCCESS"
            } else {
                Write-Log "Detach may have failed - verify manually" "WARNING"
            }
        } catch {
            Write-Log "Detach error: $($_.Exception.Message)" "WARNING"
        }
    }
    if ($linuxSession) { Remove-SSHSession -SessionId $linuxSession.SessionId -ErrorAction SilentlyContinue | Out-Null }
    if ($esxiSession) { Remove-SSHSession -SessionId $esxiSession.SessionId -ErrorAction SilentlyContinue | Out-Null }
    Write-Log "Done"
}
if ($Error.Count -gt 0) { exit 1 } else { exit 0 }
