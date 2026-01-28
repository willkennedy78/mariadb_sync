# mariadb_sync
Some scripts for extracting, syncing and staging MariaDB databases using Veeam and the vSphere API


# MariaDB Staging Sync via VMware Snapshot Disk Attachment

## Overview

Automated solution to sync a production MariaDB database to a staging environment by attaching a replica VM's disk directly to the staging VM, avoiding network transfer overhead and enabling near-instant database refresh from production snapshots.

## Architecture

**Components:**
- **ESXi Host** (a.b.c.d) - Hosts all VMs
- **Replica VM** (ID 23: `6278904 - SERVER-DB_replica`) - Production database replica, powered off
- **Staging VM** (ID 39: `SERVER-DB Staging`, 172.31.1.20) - RHEL 7 target environment, powered on
- **Control Machine** - Windows with PowerShell, Posh-SSH module

**Storage:**
- Replica disk: `/vmfs/volumes/HDD1/.../6228571 - VCSA-000023.vmdk`
- Staging disk: `/vmfs/volumes/SSD2/staging-copy.vmdk` (flattened clone)
- MariaDB data: `/var/lib/mysql/`

## Workflow

```
1. Connect to ESXi via SSH
2. Verify replica VM is powered off, staging VM is powered on
3. Get replica disk VMDK path
4. Hot-attach replica VMDK to staging VM (SCSI 0:1 or 0:2)
5. Rescan SCSI bus on staging VM
6. Import replica's LVM volume group with new name
7. Mount replica filesystem read-only
8. Stop MariaDB on staging
9. Rsync data from replica to staging
10. Restart MariaDB on staging
11. Unmount and cleanup LVM
12. Detach replica disk from staging VM
```

## Key Technical Challenges Solved

### 1. **Duplicate LVM Volume Group UUIDs**
**Problem:** Replica and staging disks both had `VolGroup` with identical UUIDs (cloned VMs)

**Solution:**
- Used LVM device filters to force visibility of only the replica disk during import:
  ```bash
  --config 'devices { filter = ["a|/dev/sdb.*|", "r|.*|"] } global { use_lvmetad = 0 }'
  ```
- Used `vgimportclone` to re-UUID and rename replica VG to `VolGroup_replica`

### 2. **XFS Duplicate Filesystem UUIDs**
**Problem:** XFS refuses to mount filesystems with duplicate UUIDs

**Solution:**
```bash
mount -o ro,nouuid /dev/VolGroup_replica/lv_root /mnt/replica-disk
```

### 3. **Sudo Without TTY**
**Problem:** SSH commands require passwordless sudo but default sudo config requires TTY

**Solution:** Added to `/etc/sudoers.d/zzz-admin`:
```
admin ALL=(ALL) NOPASSWD: ALL
```
(File sorts last alphabetically to override group permissions)

### 4. **VMware Snapshot Chains**
**Problem:** Can't detach disks part of snapshot chains, can't boot with LVM name changes

**Solution:**
- Cloned disk to flatten snapshots:
  ```bash
  vmkfstools -i "source.vmdk" -d thin "staging-rescue.vmdk"
  ```
- Edited VMX file to replace disk reference

### 5. **Large Database Rsync Timeout**
**Problem:** 30GB database sync exceeded default 5-minute SSH timeout

**Solution:**
- Increased timeout to 3600 seconds (1 hour)
- Removed `-v` (verbose) flag from rsync for performance

## PowerShell Script Configuration

**File:** `C:\Scripts\MariaDB-Staging\Sync-MariaDBStaging.ps1`

**Configuration:**
```powershell
$Config = @{
    ESXiHost = "a.b.c.d"
    StagingIP = "a.b.c.d"
    MySQLDataPath = "/var/lib/mysql"
    MountPoint = "/mnt/replica-disk"
    CredentialPath = "C:\Scripts\MariaDB-Staging"
    ReplicaVGName = "VolGroup_replica"
}
```

**Credentials (created once):**
```powershell
# Create encrypted credential files
Get-Credential | Export-Clixml C:\Scripts\MariaDB-Staging\esxi-cred.xml
Get-Credential | Export-Clixml C:\Scripts\MariaDB-Staging\linux-cred.xml
```

**Key Functions:**
- `Write-Log` - Timestamped logging with color-coded severity
- `Invoke-SSHCmd` - SSH command wrapper with configurable timeout and error handling

## ESXi Commands Used

**VM Management:**
```bash
vim-cmd vmsvc/getallvms                    # List all VMs
vim-cmd vmsvc/power.getstate <vmid>        # Check power state
vim-cmd vmsvc/device.getdevices <vmid>     # Get VM devices
```

**Disk Operations:**
```bash
# Attach existing disk
vim-cmd vmsvc/device.diskaddexisting <vmid> "<vmdk_path>" <controller> <unit>

# Detach disk
vim-cmd vmsvc/device.diskremove <vmid> <controller> <unit> <delete_file>

# Clone/flatten disk
vmkfstools -i "source.vmdk" -d thin "destination.vmdk"
```

## Linux LVM Commands

**Device scanning:**
```bash
# SCSI rescan
for h in /sys/class/scsi_host/host*; do echo '- - -' | sudo tee $h/scan >/dev/null; done
sudo partprobe

# Find new disk
lsblk -ndo NAME | grep -E "^sd[b-z]$"
```

**LVM operations:**
```bash
# Import cloned VG with new name and device filter
sudo vgimportclone --config 'devices { filter = ["a|/dev/sdb.*|", "r|.*|"] } global { use_lvmetad = 0 }' \
  -n VolGroup_replica /dev/sdb5

# Activate and mount
sudo vgchange -ay VolGroup_replica
sudo mount -o ro,nouuid /dev/VolGroup_replica/lv_root /mnt/replica-disk

# Cleanup
sudo umount /mnt/replica-disk
sudo vgchange -an VolGroup_replica
sudo vgremove -f VolGroup_replica
```

## Data Sync

**Rsync command:**
```bash
sudo rsync -a --delete \
  --exclude='*.pid' \
  --exclude='*.sock' \
  --exclude='*.err' \
  /mnt/replica-disk/var/lib/mysql/ \
  /var/lib/mysql/
```

**Flags:**
- `-a` - Archive mode (preserves permissions, ownership, timestamps)
- `--delete` - Remove files in destination not in source
- Excludes runtime files that shouldn't be copied

## Prerequisites

**Windows Control Machine:**
- PowerShell 5.1+
- Posh-SSH module: `Install-Module -Name Posh-SSH`

**ESXi:**
- SSH enabled
- Root or admin SSH access

**Staging VM:**
- RHEL/CentOS 7
- Sudo access for admin user
- Passwordless sudo configured
- MariaDB/MySQL installed
- LVM tools (pvs, vgs, lvs, vgimportclone)

## Execution

```powershell
# Manual execution
C:\Scripts\MariaDB-Staging\Sync-MariaDBStaging.ps1

# Scheduled task (Windows Task Scheduler)
# Action: PowerShell.exe
# Arguments: -ExecutionPolicy Bypass -File "C:\Scripts\MariaDB-Staging\Sync-MariaDBStaging.ps1"
```

## Logging

Logs stored in: `C:\Scripts\MariaDB-Staging\Logs\sync-YYYY-MM-DD-HHmmss.log`

Format: `[YYYY-MM-DD HH:MM:SS] [LEVEL] Message`

Levels: INFO, SUCCESS, WARNING, ERROR

## Benefits

1. **Speed** - No network transfer; direct disk access
2. **Consistency** - Point-in-time snapshot from replica
3. **Automation** - Fully scripted, can be scheduled
4. **Safety** - Replica mounted read-only, staging DB stopped during sync
5. **Space efficient** - No intermediate backup files

## Limitations

1. Requires staging and replica VMs on same ESXi host (same datastore access)
2. Replica VM must be powered off during sync
3. Staging database unavailable during sync (~15-30 min for 30GB)
4. Requires ESXi SSH access (security consideration)

## Future Enhancements

- Support for cross-datastore scenarios (storage vMotion or NFS)
- Parallel execution for multiple staging environments
- Pre/post-sync SQL scripts execution
- Slack/email notifications
- Validation checks (row counts, checksum comparison)

## Lessons Learned

1. **LVM duplicate UUIDs are common with cloned VMs** - Always use device filters with vgimportclone
2. **XFS requires `nouuid` for duplicate filesystems** - Unlike ext4 which mounts duplicates by default
3. **Sudoers file order matters** - Later entries override earlier ones; use `/etc/sudoers.d/zzz-*` for final say
4. **VMware snapshot chains prevent disk operations** - Flatten when possible for flexibility
5. **SSH timeouts need tuning for large operations** - Default 300s insufficient for 30GB+ syncs
6. **Always test recovery procedures** - VG rename broke boot; needed alternate recovery path

---

**Total Development Time:** ~4 hours of troubleshooting LVM/boot issues, 30 minutes for working script

**Script LOC:** ~214 lines PowerShell

**Typical Sync Time:** 5-15 minutes for 30GB database (varies with change volume)
