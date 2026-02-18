# Azure AD App Registration Setup

The `Sync-PendingRequests.ps1` script uses Microsoft Graph API to download JSON files
from SharePoint. This requires an Azure AD (Entra ID) app registration.

## Step 1: Create the App Registration

1. Go to [Azure Portal](https://portal.azure.com) > **Azure Active Directory** > **App registrations**
2. Click **+ New registration**
3. Configure:
   - **Name**: `SFTP Provisioning Pipeline`
   - **Supported account types**: `Accounts in this organizational directory only`
   - **Redirect URI**: Leave blank (not needed for client credentials)
4. Click **Register**
5. Note down:
   - **Application (client) ID** → goes in `config/settings.json` as `client_id`
   - **Directory (tenant) ID** → goes in `config/settings.json` as `tenant_id`

## Step 2: Add API Permissions

1. In your app registration, go to **API permissions**
2. Click **+ Add a permission**
3. Select **Microsoft Graph** > **Application permissions**
4. Add the following permissions:
   - `Sites.Read.All` — Read SharePoint sites and files
   - `Files.Read.All` — Read files in OneDrive/SharePoint (alternative to Sites.Read.All)
5. Click **Grant admin consent for [your organization]**
6. Verify the status shows a green checkmark

### Minimum Required Permissions

| Permission | Type | Purpose |
|---|---|---|
| `Sites.Read.All` | Application | Read files from SharePoint document library |

**Note**: If you want the script to also move processed files to a subfolder (so they
aren't re-downloaded), you'll need `Sites.ReadWrite.All` instead.

## Step 3: Create Client Secret

1. Go to **Certificates & secrets** > **Client secrets**
2. Click **+ New client secret**
3. Configure:
   - **Description**: `SFTP Pipeline Secret`
   - **Expires**: 24 months (set a calendar reminder to rotate)
4. Click **Add**
5. **Immediately copy the Value** (it won't be shown again)
6. Store it as an environment variable on the automation server:

```powershell
# PowerShell - set permanently for the machine
[System.Environment]::SetEnvironmentVariable("AZURE_CLIENT_SECRET", "your-secret-value", "Machine")
```

```cmd
:: Command Prompt
setx AZURE_CLIENT_SECRET "your-secret-value" /M
```

## Step 4: Find SharePoint Site and Drive IDs

### Option A: Using Graph Explorer

1. Go to [Graph Explorer](https://developer.microsoft.com/en-us/graph/graph-explorer)
2. Sign in with your M365 account and ensure you've consented to `Sites.Read.All`
   under **Modify permissions**
3. Run this query to find your site (use the exact hostname and path, not search):
   ```
   GET https://graph.microsoft.com/v1.0/sites/{hostname}:/{server-relative-path}
   ```
   For example:
   ```
   GET https://graph.microsoft.com/v1.0/sites/fttglobal.sharepoint.com:/sites/CSI
   ```
   **Note**: The `sites?search=` endpoint is unreliable — always prefer the direct
   hostname+path format above.
4. Note the `id` field (format: `hostname,site-id,web-id`)
5. Run this query to find the drive:
   ```
   GET https://graph.microsoft.com/v1.0/sites/{site-id}/drives
   ```
6. Find the drive with `name: "Documents"` (this is "Shared Documents" internally)
   and note its `id`
7. Verify the target folder is accessible:
   ```
   GET https://graph.microsoft.com/v1.0/drives/{drive-id}/root:/9. Technology/SFTP_Onboarding:/children
   ```
   **Note**: This returns 404 if the folder is empty — that's expected for a new setup.

### Option B: Using PowerShell

```powershell
# Authenticate
$tokenBody = @{
    client_id     = "your-client-id"
    scope         = "https://graph.microsoft.com/.default"
    client_secret = "your-secret"
    grant_type    = "client_credentials"
}
$token = (Invoke-RestMethod -Uri "https://login.microsoftonline.com/{tenant-id}/oauth2/v2.0/token" -Method POST -Body $tokenBody).access_token
$headers = @{ "Authorization" = "Bearer $token" }

# Get site by hostname + path (more reliable than search)
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/fttglobal.sharepoint.com:/sites/CSI" -Headers $headers |
    Select-Object displayName, id

# List drives for a site
$siteId = "your-site-id"
Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/sites/$siteId/drives" -Headers $headers |
    Select-Object -ExpandProperty value | Format-Table name, id
```

## Step 5: Update Configuration

Update `config/settings.json` with your values:

```json
{
    "azure_ad": {
        "tenant_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "client_id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "client_secret_env_var": "AZURE_CLIENT_SECRET",
        "sharepoint_site_id": "fttglobal.sharepoint.com,xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx,xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "sharepoint_drive_id": "b!xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        "sharepoint_folder_path": "9. Technology/SFTP_Onboarding"
    }
}
```

## Security Notes

- Never store the client secret in source control or configuration files
- Use environment variables or a secrets manager (Azure Key Vault, etc.)
- Rotate the client secret before it expires
- Use the minimum required permissions (principle of least privilege)
- Consider using certificate-based authentication instead of client secrets for production
