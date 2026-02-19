<#
.SYNOPSIS
    Downloads new SFTP account requests from SharePoint (populated by Power Automate).
.DESCRIPTION
    Connects to SharePoint via Microsoft Graph API and downloads JSON files from the
    configured folder. Files are moved from the SharePoint pending folder to the local
    queue/pending directory for admin review.

    This script is designed to be run on a schedule (e.g., Task Scheduler, cron).
.PARAMETER ConfigPath
    Path to the settings.json configuration file.
.EXAMPLE
    .\Sync-PendingRequests.ps1 -ConfigPath ..\config\settings.json
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\settings.json")
)

$ErrorActionPreference = "Stop"

# ── Load configuration ──────────────────────────────────────────────────────────
$configRaw = [System.IO.File]::ReadAllText((Resolve-Path $ConfigPath), [System.Text.UTF8Encoding]::new($false))
$config = ConvertFrom-Json -InputObject $configRaw
$azureConfig = $config.azure_ad
$queuePath   = Join-Path (Split-Path $ConfigPath -Parent | Split-Path -Parent) $config.general.queue_path "pending"
$logPath     = Join-Path (Split-Path $ConfigPath -Parent | Split-Path -Parent) $config.general.log_path

# Ensure directories exist
New-Item -ItemType Directory -Path $queuePath -Force | Out-Null
New-Item -ItemType Directory -Path $logPath -Force | Out-Null

# ── Logging ─────────────────────────────────────────────────────────────────────
$logFile = Join-Path $logPath "sync-$(Get-Date -Format 'yyyy-MM-dd').log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = "[$timestamp] [$Level] $Message"
    Add-Content -Path $logFile -Value $entry
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red }
        "WARNING" { Write-Host $entry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green }
        default   { Write-Host $entry }
    }
}

# ── Authenticate to Microsoft Graph ─────────────────────────────────────────────
function Get-GraphAccessToken {
    $clientSecret = [Environment]::GetEnvironmentVariable($azureConfig.client_secret_env_var)
    if (-not $clientSecret) {
        throw "Environment variable '$($azureConfig.client_secret_env_var)' is not set. Set it with your Azure AD app client secret."
    }

    $tokenBody = @{
        client_id     = $azureConfig.client_id
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $clientSecret
        grant_type    = "client_credentials"
    }

    $tokenUrl = "https://login.microsoftonline.com/$($azureConfig.tenant_id)/oauth2/v2.0/token"
    Write-Log "Requesting access token from Azure AD..."

    $response = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    return $response.access_token
}

# ── List files in SharePoint folder ─────────────────────────────────────────────
function Get-SharePointPendingFiles {
    param([string]$AccessToken)

    $headers = @{ "Authorization" = "Bearer $AccessToken" }

    # Encode the folder path for the URL
    $folderPath = $azureConfig.sharepoint_folder_path -replace '/', ':'
    $driveId = $azureConfig.sharepoint_drive_id
    $siteId  = $azureConfig.sharepoint_site_id

    # List children of the folder
    $url = "https://graph.microsoft.com/v1.0/sites/$siteId/drives/$driveId/root:/$($azureConfig.sharepoint_folder_path):/children"

    Write-Log "Fetching files from SharePoint: $($azureConfig.sharepoint_folder_path)"

    try {
        $response = Invoke-RestMethod -Uri $url -Headers $headers -Method GET
        $jsonFiles = $response.value | Where-Object { $_.name -like "*.json" }
        Write-Log "Found $($jsonFiles.Count) JSON file(s) in SharePoint."
        return $jsonFiles
    }
    catch {
        if ($_.Exception.Response.StatusCode -eq 404) {
            Write-Log "SharePoint folder not found. Ensure Power Automate is configured to write to: $($azureConfig.sharepoint_folder_path)" "WARNING"
            return @()
        }
        throw
    }
}

# ── Download a file from SharePoint ─────────────────────────────────────────────
function Get-SharePointFileContent {
    param(
        [string]$AccessToken,
        [string]$ItemId
    )

    $headers = @{ "Authorization" = "Bearer $AccessToken" }
    $driveId = $azureConfig.sharepoint_drive_id
    $siteId  = $azureConfig.sharepoint_site_id

    $url = "https://graph.microsoft.com/v1.0/sites/$siteId/drives/$driveId/items/$ItemId/content"
    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method GET
    return $response
}

# ── Move processed file to a 'processed' subfolder in SharePoint ────────────────
function Move-SharePointFile {
    param(
        [string]$AccessToken,
        [string]$ItemId,
        [string]$FileName
    )

    $headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type"  = "application/json"
    }
    $driveId = $azureConfig.sharepoint_drive_id
    $siteId  = $azureConfig.sharepoint_site_id

    # Get or create the 'processed' folder
    $processedFolderPath = "$($azureConfig.sharepoint_folder_path)/processed"
    $createFolderUrl = "https://graph.microsoft.com/v1.0/sites/$siteId/drives/$driveId/root:/$processedFolderPath"

    try {
        Invoke-RestMethod -Uri $createFolderUrl -Headers $headers -Method GET | Out-Null
    }
    catch {
        # Folder doesn't exist, create it
        $parentPath = $azureConfig.sharepoint_folder_path
        $createBody = @{
            name   = "processed"
            folder = @{}
        } | ConvertTo-Json

        $parentUrl = "https://graph.microsoft.com/v1.0/sites/$siteId/drives/$driveId/root:/$($parentPath):/children"
        Invoke-RestMethod -Uri $parentUrl -Headers $headers -Method POST -Body $createBody | Out-Null
    }

    # Get the processed folder ID
    $processedFolder = Invoke-RestMethod -Uri $createFolderUrl -Headers @{ "Authorization" = "Bearer $AccessToken" } -Method GET

    # Move the file
    $moveBody = @{
        parentReference = @{ id = $processedFolder.id }
        name = $FileName
    } | ConvertTo-Json

    $moveUrl = "https://graph.microsoft.com/v1.0/sites/$siteId/drives/$driveId/items/$ItemId"
    Invoke-RestMethod -Uri $moveUrl -Headers $headers -Method PATCH -Body $moveBody | Out-Null
}

# ── Main sync logic ─────────────────────────────────────────────────────────────
function Invoke-Sync {
    Write-Log "=== Starting SFTP request sync ===" "INFO"

    # Get existing local files to avoid duplicates
    $existingFiles = Get-ChildItem -Path $queuePath -Filter "*.json" -ErrorAction SilentlyContinue |
        ForEach-Object { $_.BaseName }

    # Also check approved, completed, rejected folders
    $allQueueBase = Split-Path $queuePath -Parent
    foreach ($subdir in @("approved", "completed", "rejected")) {
        $subPath = Join-Path $allQueueBase $subdir
        if (Test-Path $subPath) {
            $existingFiles += Get-ChildItem -Path $subPath -Filter "*.json" -ErrorAction SilentlyContinue |
                ForEach-Object { $_.BaseName }
        }
    }

    # Authenticate
    $token = Get-GraphAccessToken
    Write-Log "Authentication successful." "SUCCESS"

    # Get pending files from SharePoint
    $files = Get-SharePointPendingFiles -AccessToken $token

    $newCount = 0
    $skipCount = 0

    foreach ($file in $files) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.name)

        if ($baseName -in $existingFiles) {
            Write-Log "Skipping already-synced file: $($file.name)"
            $skipCount++
            continue
        }

        Write-Log "Downloading new request: $($file.name)"

        try {
            $content = Get-SharePointFileContent -AccessToken $token -ItemId $file.id
            $localPath = Join-Path $queuePath $file.name

            if ($content -is [string]) {
                Set-Content -Path $localPath -Value $content -Encoding UTF8
            } else {
                $content | ConvertTo-Json -Depth 10 | Set-Content -Path $localPath -Encoding UTF8
            }

            Write-Log "Saved to: $localPath" "SUCCESS"

            # Move file in SharePoint to 'processed'
            Move-SharePointFile -AccessToken $token -ItemId $file.id -FileName $file.name
            Write-Log "Moved SharePoint file to processed folder."

            $newCount++
        }
        catch {
            Write-Log "Failed to process file $($file.name): $_" "ERROR"
        }
    }

    Write-Log "=== Sync complete: $newCount new, $skipCount skipped ===" "INFO"

    if ($newCount -gt 0) {
        Write-Log "Run Review-Requests.ps1 to review and approve pending requests." "INFO"
    }
}

# ── Execute ─────────────────────────────────────────────────────────────────────
Invoke-Sync
