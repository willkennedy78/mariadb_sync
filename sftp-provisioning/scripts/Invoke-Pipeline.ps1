<#
.SYNOPSIS
    Main orchestrator for the SFTP account provisioning pipeline.
.DESCRIPTION
    Coordinates the full workflow:
      1. Sync   - Download new form responses from SharePoint
      2. Review - Interactive admin approval
      3. Provision - Create accounts on Bitvise server via SSH
      4. Report - Output summary of actions taken

    Can run individual stages or the full pipeline.
.PARAMETER Action
    Which stage to run: Sync, Review, Provision, Report, or Full (all stages).
.PARAMETER ConfigPath
    Path to the settings.json configuration file.
.PARAMETER DryRun
    If specified, provision step will validate but not create accounts.
.EXAMPLE
    .\Invoke-Pipeline.ps1 -Action Full
    .\Invoke-Pipeline.ps1 -Action Provision
    .\Invoke-Pipeline.ps1 -Action Provision -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Sync", "Review", "Provision", "Report", "Full")]
    [string]$Action,

    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\settings.json"),

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# ── Load modules ────────────────────────────────────────────────────────────────
Import-Module (Join-Path $PSScriptRoot "modules\PasswordGenerator.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\FormDataParser.psm1") -Force

# ── Load configuration ──────────────────────────────────────────────────────────
$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$baseDir   = Split-Path $ConfigPath -Parent | Split-Path -Parent
$queueBase = Join-Path $baseDir $config.general.queue_path

$approvedPath  = Join-Path $queueBase "approved"
$completedPath = Join-Path $queueBase "completed"
$logPath       = Join-Path $baseDir $config.general.log_path

foreach ($dir in @($approvedPath, $completedPath, $logPath)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

$logFile = Join-Path $logPath "pipeline-$(Get-Date -Format 'yyyy-MM-dd').log"

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

# ── SSH Remote Execution ────────────────────────────────────────────────────────
function Invoke-RemoteBitviseCommand {
    <#
    .SYNOPSIS
        Executes the provisioning script on the Bitvise server via SSH.
    .DESCRIPTION
        Copies the provisioning script to the remote server and executes it.
        Supports both Posh-SSH and native SSH client.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RequestJson,

        [Parameter(Mandatory)]
        [ValidateSet("create", "validate", "delete")]
        [string]$ProvisionAction,

        [Parameter(Mandatory)]
        [string]$Environment,

        [string]$Password = ""
    )

    $bitviseConfig = $config.bitvise
    $remoteScript  = $bitviseConfig.provisioning_script_remote_path
    $server        = $bitviseConfig.server_host
    $port          = $bitviseConfig.ssh_port
    $sshUser       = $bitviseConfig.ssh_username
    $comObject     = $bitviseConfig.com_object_name

    $baseMountPath = if ($Environment -eq "test") {
        $bitviseConfig.base_mount_path_test
    } else {
        $bitviseConfig.base_mount_path_prod
    }

    # Escape the JSON for command-line passing
    $escapedJson = $RequestJson -replace '"', '\"'

    # Build the remote PowerShell command
    $remoteCmd = "powershell -ExecutionPolicy Bypass -File `"$remoteScript`" " +
                 "-RequestJson `"$escapedJson`" " +
                 "-Action $ProvisionAction " +
                 "-Environment $Environment " +
                 "-ComObjectName `"$comObject`" " +
                 "-BaseMountPath `"$baseMountPath`""

    if ($Password) {
        $remoteCmd += " -Password `"$Password`""
    }

    # Try native SSH first (PowerShell 7+ or OpenSSH client)
    Write-Log "Connecting to Bitvise server: $server"

    $sshKeyPath = $bitviseConfig.ssh_key_path
    $sshPasswordEnvVar = $bitviseConfig.ssh_password_env_var

    if ($sshKeyPath -and (Test-Path $sshKeyPath)) {
        # Key-based authentication
        Write-Log "Using SSH key authentication: $sshKeyPath"
        $output = ssh -i $sshKeyPath -p $port "${sshUser}@${server}" $remoteCmd 2>&1
    }
    elseif (Get-Module -ListAvailable -Name Posh-SSH) {
        # Posh-SSH fallback
        Write-Log "Using Posh-SSH module for connection."
        $sshPassword = [Environment]::GetEnvironmentVariable($sshPasswordEnvVar)
        if (-not $sshPassword) {
            throw "SSH password not found in environment variable '$sshPasswordEnvVar'."
        }

        $secPassword = ConvertTo-SecureString $sshPassword -AsPlainText -Force
        $credential  = New-Object System.Management.Automation.PSCredential($sshUser, $secPassword)

        $session = New-SSHSession -ComputerName $server -Port $port -Credential $credential -AcceptKey
        try {
            $sshResult = Invoke-SSHCommand -SessionId $session.SessionId -Command $remoteCmd -TimeOut 120
            $output = $sshResult.Output
            if ($sshResult.ExitStatus -ne 0) {
                Write-Log "Remote command exited with status $($sshResult.ExitStatus)" "WARNING"
            }
        }
        finally {
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
        }
    }
    else {
        throw "No SSH client available. Install OpenSSH client or Posh-SSH module."
    }

    # Parse the output as JSON result
    $outputStr = ($output | Out-String).Trim()

    # Extract JSON from output (the script outputs JSON at the end)
    $jsonMatch = [regex]::Match($outputStr, '\{[\s\S]*\}$')
    if ($jsonMatch.Success) {
        return $jsonMatch.Value | ConvertFrom-Json
    }

    Write-Log "Remote output: $outputStr" "WARNING"
    return @{ success = $false; message = "Could not parse remote output: $outputStr" }
}

function Deploy-ProvisioningScript {
    <#
    .SYNOPSIS
        Deploys the Provision-SFTPAccount.ps1 script to the Bitvise server.
    #>
    $bitviseConfig = $config.bitvise
    $localScript   = Join-Path $PSScriptRoot "Provision-SFTPAccount.ps1"
    $remotePath    = $bitviseConfig.provisioning_script_remote_path
    $remoteDir     = Split-Path $remotePath -Parent

    $server  = $bitviseConfig.server_host
    $port    = $bitviseConfig.ssh_port
    $sshUser = $bitviseConfig.ssh_username

    Write-Log "Deploying provisioning script to $server..."

    $sshKeyPath = $bitviseConfig.ssh_key_path
    $sshPasswordEnvVar = $bitviseConfig.ssh_password_env_var

    if ($sshKeyPath -and (Test-Path $sshKeyPath)) {
        # Create directory and copy via SCP
        ssh -i $sshKeyPath -p $port "${sshUser}@${server}" "if not exist `"$remoteDir`" mkdir `"$remoteDir`""
        scp -i $sshKeyPath -P $port $localScript "${sshUser}@${server}:${remotePath}"
    }
    elseif (Get-Module -ListAvailable -Name Posh-SSH) {
        $sshPassword = [Environment]::GetEnvironmentVariable($sshPasswordEnvVar)
        $secPassword = ConvertTo-SecureString $sshPassword -AsPlainText -Force
        $credential  = New-Object System.Management.Automation.PSCredential($sshUser, $secPassword)

        $session = New-SSHSession -ComputerName $server -Port $port -Credential $credential -AcceptKey
        try {
            Invoke-SSHCommand -SessionId $session.SessionId -Command "if not exist `"$remoteDir`" mkdir `"$remoteDir`""
            # Use SFTP to upload
            $sftpSession = New-SFTPSession -ComputerName $server -Port $port -Credential $credential
            try {
                Set-SFTPItem -SessionId $sftpSession.SessionId -Path $localScript -Destination $remoteDir -Force
            }
            finally {
                Remove-SFTPSession -SessionId $sftpSession.SessionId | Out-Null
            }
        }
        finally {
            Remove-SSHSession -SessionId $session.SessionId | Out-Null
        }
    }
    else {
        throw "No SSH/SCP client available for script deployment."
    }

    Write-Log "Provisioning script deployed to $remotePath" "SUCCESS"
}

# ── Provision Stage ─────────────────────────────────────────────────────────────
function Invoke-Provision {
    Write-Log "=== Starting provisioning stage ===" "INFO"

    $approvedFiles = Get-ChildItem -Path $approvedPath -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object CreationTime

    if ($approvedFiles.Count -eq 0) {
        Write-Log "No approved requests to provision." "INFO"
        return
    }

    Write-Log "Found $($approvedFiles.Count) approved request(s) to provision."

    # Deploy the provisioning script to the remote server
    try {
        Deploy-ProvisioningScript
    }
    catch {
        Write-Log "Failed to deploy provisioning script: $_" "ERROR"
        Write-Log "Ensure SSH connectivity to $($config.bitvise.server_host) is configured." "ERROR"
        return
    }

    $passwordDefaults = @{}
    foreach ($prop in $config.password_defaults.PSObject.Properties) {
        $passwordDefaults[$prop.Name] = $prop.Value
    }

    foreach ($file in $approvedFiles) {
        Write-Log "Processing: $($file.Name)"

        $request = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $requestJson = $request | ConvertTo-Json -Depth 10 -Compress

        # Determine environments to provision
        $environments = $request.environment
        if ($environments -is [string]) { $environments = @($environments) }

        # Expand "both" into test + production
        if ($environments -contains "both") {
            $environments = @("test", "production")
        }

        $allSuccess = $true
        $provisionResults = @()

        foreach ($env in $environments) {
            Write-Log "  Provisioning for $env environment..."

            # ── Generate password if needed ──────────────────────────────────
            $password = ""
            if ($request.auth_method -eq "password" -or $request.auth_method -eq "both") {
                $pwParams = ConvertTo-PasswordParams `
                    -HasRestrictions $request.password_restrictions `
                    -RestrictionDetails $request.password_requirements_detail `
                    -Defaults $passwordDefaults

                $password = New-SFTPPassword @pwParams
                Write-Log "  Generated password ($($pwParams.Length) chars)."
            }

            # ── Validate first ───────────────────────────────────────────────
            if (-not $DryRun) {
                Write-Log "  Validating account doesn't already exist..."
                $validateResult = Invoke-RemoteBitviseCommand `
                    -RequestJson $requestJson `
                    -ProvisionAction "validate" `
                    -Environment $env

                if (-not $validateResult.success) {
                    Write-Log "  Validation failed: $($validateResult.message)" "ERROR"
                    $allSuccess = $false
                    $provisionResults += $validateResult
                    continue
                }
            }

            # ── Create the account ───────────────────────────────────────────
            $actionType = if ($DryRun) { "validate" } else { "create" }
            Write-Log "  $( if ($DryRun) { 'DRY RUN - Validating' } else { 'Creating' } ) account..."

            $createResult = Invoke-RemoteBitviseCommand `
                -RequestJson $requestJson `
                -ProvisionAction $actionType `
                -Environment $env `
                -Password $password

            if ($createResult.success) {
                Write-Log "  $($createResult.message)" "SUCCESS"

                # Store credential info for delivery (DO NOT log the actual password)
                $credentialInfo = [PSCustomObject]@{
                    username         = if ($env -eq "test") { $request.username_test } else { $request.username_prod }
                    environment      = $env
                    auth_method      = $request.auth_method
                    password         = $password
                    delivery_method  = $request.delivery_method
                    recipient_email  = $request.recipient_email
                    recipient_phone  = $request.recipient_phone
                    customer_name    = $request.customer_name
                }

                # Save credential info to a secure file for the credential delivery step
                $credDir = Join-Path $completedPath "credentials"
                New-Item -ItemType Directory -Path $credDir -Force | Out-Null
                $credFile = Join-Path $credDir "$($credentialInfo.username)_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
                $credentialInfo | ConvertTo-Json -Depth 5 | Set-Content -Path $credFile -Encoding UTF8
                Write-Log "  Credential info saved to: $credFile"
                Write-Log "  ** Deliver credentials via $($request.delivery_method) to $($request.recipient_email) **" "WARNING"
            }
            else {
                Write-Log "  FAILED: $($createResult.message)" "ERROR"
                $allSuccess = $false
            }

            $provisionResults += $createResult
        }

        # ── Move to completed or leave for retry ────────────────────────────
        if ($allSuccess -and -not $DryRun) {
            $request.status = "completed"
            $request.provisioned_at = (Get-Date -Format "o")
            $request | Add-Member -NotePropertyName "provision_results" -NotePropertyValue $provisionResults -Force

            $request | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $completedPath $file.Name) -Encoding UTF8
            Remove-Item $file.FullName -Force

            Write-Log "  Request completed and moved to completed queue." "SUCCESS"
        }
        elseif ($DryRun) {
            Write-Log "  DRY RUN complete - no changes made." "INFO"
        }
        else {
            Write-Log "  Request had failures - kept in approved queue for retry." "WARNING"
        }
    }

    Write-Log "=== Provisioning stage complete ===" "INFO"
}

# ── Report Stage ────────────────────────────────────────────────────────────────
function Invoke-Report {
    Write-Host ""
    Write-Host "  =================================================" -ForegroundColor Cyan
    Write-Host "  SFTP Provisioning Pipeline - Status Report" -ForegroundColor Cyan
    Write-Host "  =================================================" -ForegroundColor Cyan
    Write-Host ""

    $dirs = @{
        "Pending"   = Join-Path $queueBase "pending"
        "Approved"  = $approvedPath
        "Completed" = $completedPath
        "Rejected"  = Join-Path $queueBase "rejected"
    }

    foreach ($entry in $dirs.GetEnumerator()) {
        $count = if (Test-Path $entry.Value) {
            (Get-ChildItem -Path $entry.Value -Filter "*.json" -ErrorAction SilentlyContinue).Count
        } else { 0 }

        $color = switch ($entry.Key) {
            "Pending"   { if ($count -gt 0) { "Yellow" } else { "Gray" } }
            "Approved"  { if ($count -gt 0) { "Cyan"   } else { "Gray" } }
            "Completed" { "Green" }
            "Rejected"  { if ($count -gt 0) { "Red"    } else { "Gray" } }
        }

        Write-Host "  $($entry.Key):".PadRight(15) -NoNewline
        Write-Host "$count request(s)" -ForegroundColor $color
    }

    # Show recent completions
    $recentCompleted = Get-ChildItem -Path $completedPath -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 5

    if ($recentCompleted.Count -gt 0) {
        Write-Host ""
        Write-Host "  Recent Completions:" -ForegroundColor Green
        foreach ($file in $recentCompleted) {
            $req = Get-Content $file.FullName -Raw | ConvertFrom-Json
            Write-Host "    - $($req.customer_name) ($($req.environment -join ', ')) - $($req.provisioned_at)" -ForegroundColor Gray
        }
    }

    # Check for pending credential deliveries
    $credDir = Join-Path $completedPath "credentials"
    if (Test-Path $credDir) {
        $pendingCreds = Get-ChildItem -Path $credDir -Filter "*.json" -ErrorAction SilentlyContinue
        if ($pendingCreds.Count -gt 0) {
            Write-Host ""
            Write-Host "  PENDING CREDENTIAL DELIVERIES: $($pendingCreds.Count)" -ForegroundColor Yellow
            foreach ($cred in $pendingCreds) {
                $credData = Get-Content $cred.FullName -Raw | ConvertFrom-Json
                Write-Host "    - $($credData.username) -> $($credData.recipient_email) via $($credData.delivery_method)" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
}

# ── Main Orchestrator ───────────────────────────────────────────────────────────
Write-Log "Pipeline started with action: $Action"

switch ($Action) {
    "Sync" {
        & (Join-Path $PSScriptRoot "Sync-PendingRequests.ps1") -ConfigPath $ConfigPath
    }
    "Review" {
        & (Join-Path $PSScriptRoot "Review-Requests.ps1") -ConfigPath $ConfigPath
    }
    "Provision" {
        Invoke-Provision
    }
    "Report" {
        Invoke-Report
    }
    "Full" {
        Write-Log "Running full pipeline..." "INFO"
        Write-Host ""

        # Step 1: Sync
        Write-Host "  [1/4] Syncing new requests from SharePoint..." -ForegroundColor Cyan
        try {
            & (Join-Path $PSScriptRoot "Sync-PendingRequests.ps1") -ConfigPath $ConfigPath
        }
        catch {
            Write-Log "Sync failed: $_ -- continuing to review any existing pending requests." "WARNING"
        }

        # Step 2: Review
        Write-Host ""
        Write-Host "  [2/4] Review pending requests..." -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot "Review-Requests.ps1") -ConfigPath $ConfigPath

        # Step 3: Provision
        Write-Host ""
        Write-Host "  [3/4] Provisioning approved accounts..." -ForegroundColor Cyan
        Invoke-Provision

        # Step 4: Report
        Write-Host ""
        Write-Host "  [4/4] Pipeline Report" -ForegroundColor Cyan
        Invoke-Report

        Write-Log "Full pipeline run complete." "SUCCESS"
    }
}
