# SFTP Account Provisioning Pipeline

Automated pipeline for provisioning Bitvise SSH Server SFTP accounts from Microsoft Forms
customer requests.

## Architecture

```
Microsoft Forms          Power Automate          SharePoint             Automation Server
+----------------+      +----------------+      +----------------+     +-------------------+
| Customer fills |----->| Triggers on    |----->| JSON file per  |---->| Sync-Pending      |
| out SFTP       |      | new response,  |      | request in     |     | Requests.ps1      |
| request form   |      | extracts data, |      | /SFTP-Requests/|     | downloads new     |
+----------------+      | writes JSON    |      | pending/       |     | requests          |
                        +----------------+      +----------------+     +--------+----------+
                                                                                |
                                                                                v
                                                                       +-------------------+
                                                                       | Review-Requests   |
                                                                       | .ps1              |
                                                                       | Admin reviews &   |
                                                                       | approves/rejects  |
                                                                       +--------+----------+
                                                                                |
                                                                                v
                                                                       +-------------------+
                                                                       | Invoke-Pipeline   |     SSH      +------------------+
                                                                       | .ps1 -Action      |------------->| Bitvise SSH      |
                                                                       | Provision         |              | Server (v8.xx)   |
                                                                       | Generates password|              | BssCfg COM       |
                                                                       | Connects via SSH  |              | creates virtual  |
                                                                       +-------------------+              | account          |
                                                                                                          +------------------+
```

## Pipeline Stages

| Stage | Script | Purpose |
|-------|--------|---------|
| **Sync** | `Sync-PendingRequests.ps1` | Downloads new JSON files from SharePoint via Graph API |
| **Review** | `Review-Requests.ps1` | Interactive CLI for admin approval/rejection |
| **Provision** | `Invoke-Pipeline.ps1 -Action Provision` | Creates Bitvise virtual accounts via SSH |
| **Report** | `Invoke-Pipeline.ps1 -Action Report` | Shows queue status and pending actions |
| **Full** | `Invoke-Pipeline.ps1 -Action Full` | Runs all stages sequentially |

## Quick Start

### 1. Prerequisites

- PowerShell 5.1+ (PowerShell 7+ recommended)
- [Posh-SSH](https://github.com/darkoperator/Posh-SSH) module (for SSH to Bitvise server)
- Azure AD app registration with `Sites.Read.All` permission
- Microsoft 365 account with Power Automate access
- Bitvise SSH Server v8.xx on the target Windows server

```powershell
# Install Posh-SSH
Install-Module -Name Posh-SSH -Scope CurrentUser
```

### 2. Azure AD Setup

Follow [docs/azure-app-registration.md](docs/azure-app-registration.md) to:
- Create an app registration
- Configure permissions
- Get the tenant ID, client ID, and client secret

### 3. Power Automate Flow

Follow [docs/power-automate-setup.md](docs/power-automate-setup.md) to:
- Create the flow that captures form responses
- Write JSON files to SharePoint

### 4. Configuration

Edit `config/settings.json` with your environment values:

```json
{
    "azure_ad": {
        "tenant_id": "YOUR_TENANT_GUID",
        "client_id": "YOUR_APP_CLIENT_ID",
        "sharepoint_site_id": "YOUR_SITE_ID",
        "sharepoint_drive_id": "YOUR_DRIVE_ID"
    },
    "bitvise": {
        "server_host": "YOUR_BITVISE_SERVER_IP",
        "ssh_username": "admin",
        "com_object_name": "BssCfg815.BssCfg815",
        "base_mount_path_test": "D:\\SFTP\\Test",
        "base_mount_path_prod": "D:\\SFTP\\Prod"
    }
}
```

### 5. Set Environment Variables

```powershell
# Azure AD client secret
[Environment]::SetEnvironmentVariable("AZURE_CLIENT_SECRET", "your-secret", "Machine")

# Bitvise SSH password (if not using key auth)
[Environment]::SetEnvironmentVariable("BITVISE_SSH_PASSWORD", "your-password", "Machine")
```

### 6. Deploy Provisioning Script to Bitvise Server

The `Provision-SFTPAccount.ps1` script must be present on the Bitvise server. The pipeline
deploys it automatically via SCP, or you can copy it manually:

```powershell
# Manually copy to the Bitvise server
scp scripts/Provision-SFTPAccount.ps1 admin@bitvise-server:C:\Scripts\SFTP-Provisioning\
```

### 7. Run the Pipeline

```powershell
# Full pipeline (sync + review + provision + report)
.\scripts\Invoke-Pipeline.ps1 -Action Full

# Individual stages
.\scripts\Invoke-Pipeline.ps1 -Action Sync
.\scripts\Invoke-Pipeline.ps1 -Action Review
.\scripts\Invoke-Pipeline.ps1 -Action Provision
.\scripts\Invoke-Pipeline.ps1 -Action Report

# Dry run (validate without creating accounts)
.\scripts\Invoke-Pipeline.ps1 -Action Provision -DryRun
```

## Form Fields Mapping

The Microsoft Forms collects the following information from customers:

| Form Question | Internal Field | Bitvise Mapping |
|---|---|---|
| Customer Name | `customer_name` | Account name prefix |
| Requester Name | `requester_name` | Audit trail |
| Environment (Test/Prod/Both) | `environment` | Which server config to provision |
| Authentication method | `auth_method` | Password, public key, or both |
| Password restrictions | `password_restrictions` | Password generation rules |
| Password requirement details | `password_requirements_detail` | Specific constraints |
| Public key | `public_key` | Imported via `auth.keys.ImportFromFile()` |
| Credential delivery method | `delivery_method` | SMS, WhatsApp, or Telegram |
| Recipient email | `recipient_email` | Dissolvable link destination |
| Recipient phone | `recipient_phone` | 2FA delivery for credential link |
| IP whitelist | `ip_whitelist` | Per-account IP access rules |

## Queue Structure

```
queue/
├── pending/        # New requests downloaded from SharePoint, awaiting review
├── approved/       # Admin-approved requests, awaiting provisioning
├── completed/      # Successfully provisioned requests
│   └── credentials/  # Credential files for delivery (sensitive - secure this folder)
└── rejected/       # Rejected requests with rejection reasons
```

## Credential Delivery

After provisioning, credential information is saved to `queue/completed/credentials/`.
Each file contains the username, generated password, and delivery instructions.

**Current process**: Manual delivery using the customer's chosen method (SMS, WhatsApp,
or Telegram) via a password-protected dissolvable link service.

**Recommended services** for dissolvable credential links:
- [PrivateBin](https://privatebin.info/)
- [OneTimeSecret](https://onetimesecret.com/)
- [Yopass](https://yopass.se/)

## Scheduling

To run the sync automatically, create a Windows Task Scheduler job:

```powershell
# Create a scheduled task to sync every 15 minutes
$action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument "-File C:\path\to\scripts\Sync-PendingRequests.ps1"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
Register-ScheduledTask -TaskName "SFTP-Request-Sync" -Action $action -Trigger $trigger -RunLevel Highest
```

## Security Considerations

- **Secrets**: Never commit client secrets, SSH keys, or passwords to source control
- **Credentials folder**: The `queue/completed/credentials/` folder contains generated
  passwords. Secure it with appropriate NTFS permissions and delete credential files
  after delivery
- **SSH access**: Use key-based SSH authentication to the Bitvise server where possible
- **Bitvise COM lock**: The provisioning script follows the required Lock/Load/Save/Unlock
  pattern. If the script crashes mid-operation, you may need to manually unlock via the
  Bitvise GUI
- **IP validation**: The pipeline validates IP addresses/CIDR ranges before provisioning
  but always verify the whitelist entries are correct during the review step

## Troubleshooting

### Sync fails with authentication error
- Verify the Azure AD client secret environment variable is set
- Check the client secret hasn't expired
- Confirm admin consent was granted for the app permissions

### SSH connection fails
- Verify the Bitvise server allows SSH connections from the automation server's IP
- Check the SSH username and credentials
- Ensure Posh-SSH module is installed: `Get-Module -ListAvailable Posh-SSH`

### BssCfg COM object fails
- Verify the COM object name matches your Bitvise version
- Ensure the provisioning script runs with admin privileges on the Bitvise server
- Check that no other process has the settings locked (use Bitvise GUI to verify)

### Account already exists error
- The pipeline validates before creating. Use the `delete` action to remove an
  existing account before recreating, or modify the username in the review step.
