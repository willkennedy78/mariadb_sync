<#
.SYNOPSIS
    Main orchestrator for the SFTP account provisioning pipeline.
.DESCRIPTION
    Coordinates the full workflow:
      1. Sync   - Download new form responses from SharePoint
      2. Review - Interactive admin approval
      3. Provision - Create accounts on Bitvise server via SSH or PS Remoting
      4. Report - Output summary of actions taken

    Can run individual stages or the full pipeline.
.PARAMETER Action
    Which stage to run: Sync, Review, Provision, Report, or Full (all stages).
.PARAMETER ConfigPath
    Path to the settings.json configuration file.
.PARAMETER DryRun
    If specified, provision step will validate but not create accounts.
.PARAMETER ForceSync
    If specified, re-downloads files from SharePoint even if they already exist locally in pending.
.EXAMPLE
    .\Invoke-Pipeline.ps1 -Action Full
    .\Invoke-Pipeline.ps1 -Action Full -ForceSync
    .\Invoke-Pipeline.ps1 -Action Provision
    .\Invoke-Pipeline.ps1 -Action Provision -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("Sync", "Review", "Provision", "Report", "Full")]
    [string]$Action,

    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\settings.json"),

    [switch]$DryRun,

    [switch]$ForceSync
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Load modules ────────────────────────────────────────────────────────────────
Import-Module (Join-Path $PSScriptRoot "modules\PasswordGenerator.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "modules\FormDataParser.psm1") -Force

# ── Load configuration ──────────────────────────────────────────────────────────
if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath (resolved from PSScriptRoot='$PSScriptRoot')"
}
$ConfigPath = (Resolve-Path $ConfigPath).Path
$configRaw = (Get-Content -Path $ConfigPath -Raw -Encoding UTF8).Trim()
try {
    $config = ConvertFrom-Json -InputObject $configRaw
} catch {
    throw "Failed to parse '$ConfigPath': $($_.Exception.Message)`nCheck for missing closing braces or trailing commas in your JSON."
}
foreach ($section in @('general', 'bitvise', 'form_field_mapping')) {
    if (-not $config.$section) {
        throw "Configuration '$ConfigPath' is missing required section: '$section'"
    }
}
$baseDir   = Split-Path (Split-Path $ConfigPath -Parent) -Parent
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

# ── Helpers ───────────────────────────────────────────────────────────────────────
function Resolve-SecretValue {
    param([string]$ConfigValue)
    $fromEnv = [Environment]::GetEnvironmentVariable($ConfigValue)
    if ($fromEnv) { return $fromEnv }
    if ($ConfigValue -and $ConfigValue -notmatch '^[A-Z_]+$') { return $ConfigValue }
    return $null
}

# ── Remote Execution ─────────────────────────────────────────────────────────────

function Invoke-RemoteBitviseCommand {
    <#
    .SYNOPSIS
        Executes the provisioning script on the Bitvise server via SSH or PS Remoting.
    .DESCRIPTION
        SSH transport (default): Uses plink.exe or ssh.exe to run the pre-deployed
        provisioning script on the remote server. Each call is independent — no
        session to manage, and COM objects work because SSH provides a proper logon
        session.

        PSRemoting transport (legacy): Uses Invoke-Command -FilePath via WinRM.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$RequestJson,

        [Parameter(Mandatory)]
        [ValidateSet("create", "validate", "delete")]
        [string]$ProvisionAction,

        [Parameter(Mandatory)]
        [string]$Environment,

        [string]$Password = "",

        # Only used for psremoting transport
        [System.Management.Automation.Runspaces.PSSession]$Session
    )

    $bitviseConfig = $config.bitvise
    $comObject     = $bitviseConfig.com_object_name
    $transport     = if ($bitviseConfig.transport) { $bitviseConfig.transport } else { "psremoting" }

    $baseMountPath = if ($Environment -eq "test") {
        $bitviseConfig.base_mount_path_test
    } else {
        $bitviseConfig.base_mount_path_prod
    }

    Write-Log "Executing provisioning script on $($bitviseConfig.computer_name) ($ProvisionAction / $Environment) via $transport"

    if ($transport -eq "ssh") {
        return Invoke-SshBitviseCommand `
            -RequestJson $RequestJson `
            -ProvisionAction $ProvisionAction `
            -Environment $Environment `
            -Password $Password `
            -ComObjectName $comObject `
            -BaseMountPath $baseMountPath
    }

    # ── PS Remoting fallback ─────────────────────────────────────────────
    if (-not $Session) {
        return @{ success = $false; message = "PSRemoting transport requires a session." }
    }

    $localScript = Join-Path $PSScriptRoot "Provision-SFTPAccount.ps1"

    try {
        $output = Invoke-Command -Session $Session `
            -FilePath $localScript `
            -ArgumentList $RequestJson, $ProvisionAction, $Environment, $Password, $comObject, $baseMountPath
    }
    catch {
        Write-Log "Remote command failed: $_" "ERROR"
        return @{ success = $false; message = "Remote execution failed: $_" }
    }

    return ConvertFrom-RemoteOutput $output
}

function Invoke-SshBitviseCommand {
    <#
    .SYNOPSIS
        Executes the provisioning script on the Bitvise server over SSH.
    .DESCRIPTION
        Supports two SSH clients:
          - plink (default): PuTTY's command-line SSH client. Supports -pw for
            password auth — works on Server 2016 with no OS features needed.
            Download plink.exe and put it on PATH or set ssh_client_path.
          - ssh: OpenSSH client (Windows 10 1809+ / Server 2019+). Key auth only.

        The request JSON is base64-encoded to avoid escaping issues across the
        SSH/shell boundary. The entire remote command is passed via
        powershell.exe -EncodedCommand.
    #>
    param(
        [Parameter(Mandatory)][string]$RequestJson,
        [Parameter(Mandatory)][string]$ProvisionAction,
        [Parameter(Mandatory)][string]$Environment,
        [string]$Password = "",
        [string]$ComObjectName = "",
        [string]$BaseMountPath = ""
    )

    $bitviseConfig = $config.bitvise
    $server        = $bitviseConfig.computer_name
    $sshUser       = if ($bitviseConfig.ssh_user) { $bitviseConfig.ssh_user } else { "service_sftp" }
    $sshPort       = if ($bitviseConfig.ssh_port) { $bitviseConfig.ssh_port } else { 22 }
    $sshKeyPath    = $bitviseConfig.ssh_key_path
    $sshClient     = if ($bitviseConfig.ssh_client) { $bitviseConfig.ssh_client } else { "plink" }
    $sshClientPath = $bitviseConfig.ssh_client_path
    $remoteScript  = $bitviseConfig.remote_script_path

    if (-not $remoteScript) {
        return @{ success = $false; message = "SSH transport requires 'remote_script_path' in bitvise config." }
    }

    # Resolve the SSH client executable
    $sshExe = if ($sshClientPath) { $sshClientPath } else { "$sshClient.exe" }

    # Base64-encode the JSON to safely pass through SSH
    $jsonB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($RequestJson))

    # Build the PowerShell script block to run on the remote server.
    # It decodes the base64 JSON and calls the provisioning script.
    $escapedPassword = $Password -replace "'", "''"
    $escapedMount    = $BaseMountPath -replace "'", "''"

    $remoteBlock = @"
`$json = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$jsonB64'))
& '$remoteScript' -RequestJson `$json -Action '$ProvisionAction' -Environment '$Environment' -Password '$escapedPassword' -ComObjectName '$ComObjectName' -BaseMountPath '$escapedMount'
"@

    # Encode the entire block for powershell.exe -EncodedCommand
    $encodedCmd = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($remoteBlock))
    $remoteCommand = "powershell.exe -ExecutionPolicy Bypass -EncodedCommand $encodedCmd"

    # Build client-specific arguments
    $usePlinkStdinPassword = $false
    if ($sshClient -eq "plink") {
        $sshArgs = @(
            "-P", $sshPort,     # Port (uppercase -P for plink)
            "-l", $sshUser      # Login username
        )
        # Auth: key file takes priority, otherwise fall back to password
        if ($sshKeyPath) {
            $sshArgs += "-i", $sshKeyPath
            $sshArgs = @("-batch") + $sshArgs   # -batch is safe with key auth
        } else {
            $sshPassword = Resolve-SecretValue $bitviseConfig.credential_password_env_var
            if ($sshPassword) {
                # Use stdin to feed the password. This works with both
                # "password" and "keyboard-interactive" server auth methods,
                # whereas -pw only works with plain password auth.
                $usePlinkStdinPassword = $true
            }
        }
        $sshArgs += $server
        $sshArgs += $remoteCommand
    }
    else {
        # OpenSSH ssh.exe
        $sshArgs = @(
            "-o", "StrictHostKeyChecking=no",
            "-o", "BatchMode=yes",
            "-p", $sshPort
        )
        if ($sshKeyPath) {
            $sshArgs += "-i", $sshKeyPath
        }
        $sshArgs += "$sshUser@$server"
        $sshArgs += $remoteCommand
    }

    try {
        if ($usePlinkStdinPassword) {
            # Pipe password via stdin so plink can answer keyboard-interactive prompts.
            # echo "password" | plink ... sends the password followed by a newline.
            $output = ($sshPassword | & $sshExe @sshArgs) 2>&1
        } else {
            $output = & $sshExe @sshArgs 2>&1
        }
        $exitCode = $LASTEXITCODE
    }
    catch {
        Write-Log "SSH execution error: $_" "ERROR"
        return @{ success = $false; message = "SSH failed ($sshExe): $_" }
    }

    if ($null -eq $output -and $exitCode -ne 0) {
        return @{ success = $false; message = "SSH returned exit code $exitCode with no output. Verify $sshExe is on PATH and credentials are correct." }
    }

    return ConvertFrom-RemoteOutput $output
}

function ConvertFrom-RemoteOutput {
    <# Extracts a JSON result object from remote command output. #>
    param($Output)

    $outputStr = ($Output | Out-String).Trim()

    $jsonMatch = [regex]::Match($outputStr, '\{[\s\S]*\}$')
    if ($jsonMatch.Success) {
        return ConvertFrom-Json -InputObject $jsonMatch.Value
    }

    Write-Log "Remote output: $outputStr" "WARNING"
    return @{ success = $false; message = "Could not parse remote output: $outputStr" }
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

    $transport = if ($config.bitvise.transport) { $config.bitvise.transport } else { "psremoting" }
    Write-Log "Transport: $transport"

    # ── PS Remoting: establish session up front ──────────────────────────
    $session = $null
    if ($transport -eq "psremoting") {
        try {
            Write-Log "Establishing PS Remoting session to $($config.bitvise.computer_name)..."
            $credUser = $config.bitvise.credential_username
            $credPass = Resolve-SecretValue $config.bitvise.credential_password_env_var
            if (-not $credPass) {
                throw "Cannot resolve Bitvise password. Set environment variable '$($config.bitvise.credential_password_env_var)'."
            }
            $secPass    = ConvertTo-SecureString $credPass -AsPlainText -Force
            $credential = New-Object System.Management.Automation.PSCredential($credUser, $secPass)
            $sessionParams = @{ ComputerName = $config.bitvise.computer_name; Credential = $credential; EnableNetworkAccess = $true }
            if ($config.bitvise.use_ssl)          { $sessionParams.UseSSL = $true }
            if ($config.bitvise.authentication)    { $sessionParams.Authentication = $config.bitvise.authentication }
            $session = New-PSSession @sessionParams
            Write-Log "Connected to $($session.ComputerName) via PS Remoting." "SUCCESS"
        }
        catch {
            Write-Log "Failed to connect to Bitvise server: $_" "ERROR"
            return
        }
    } else {
        Write-Log "Using SSH ($( if ($config.bitvise.ssh_client) { $config.bitvise.ssh_client } else { 'plink' })) to $($config.bitvise.computer_name):$($config.bitvise.ssh_port) as $($config.bitvise.ssh_user)"
    }

    $passwordDefaults = @{}
    foreach ($prop in $config.password_defaults.PSObject.Properties) {
        $passwordDefaults[$prop.Name] = $prop.Value
    }

    try {
    foreach ($file in $approvedFiles) {
        Write-Log "Processing: $($file.Name)"

        $request = ConvertFrom-Json -InputObject (Get-Content $file.FullName -Raw -Encoding UTF8)
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
                    -Environment $env `
                    -Session $session

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
                -Password $password `
                -Session $session

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
    }
    finally {
        if ($session) {
            Remove-PSSession $session
            Write-Log "PS Remoting session closed."
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
            $req = ConvertFrom-Json -InputObject (Get-Content $file.FullName -Raw -Encoding UTF8)
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
                $credData = ConvertFrom-Json -InputObject (Get-Content $cred.FullName -Raw -Encoding UTF8)
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
        $syncArgs = @{ ConfigPath = $ConfigPath }
        if ($ForceSync) { $syncArgs.Force = $true }
        & (Join-Path $PSScriptRoot "Sync-PendingRequests.ps1") @syncArgs
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
            $syncArgs = @{ ConfigPath = $ConfigPath }
            if ($ForceSync) { $syncArgs.Force = $true }
            & (Join-Path $PSScriptRoot "Sync-PendingRequests.ps1") @syncArgs
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
