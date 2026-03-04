<#
.SYNOPSIS
    Main orchestrator for the SFTP account provisioning pipeline.
.DESCRIPTION
    Coordinates the full workflow:
      1. Sync   - Download new form responses from SharePoint
      2. Review - Interactive admin approval
      3. Provision - Create accounts on Bitvise server via PS Remoting
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

# ── PS Remoting ──────────────────────────────────────────────────────────────────
function New-BitviseSession {
    <#
    .SYNOPSIS
        Creates a PS Remoting session to the Bitvise SSH Server machine.
    #>
    $bitviseConfig = $config.bitvise
    $server        = $bitviseConfig.computer_name

    $credUser    = $bitviseConfig.credential_username
    $credPass    = Resolve-SecretValue $bitviseConfig.credential_password_env_var
    if (-not $credPass) {
        throw "Cannot resolve Bitvise password. Set environment variable '$($bitviseConfig.credential_password_env_var)' or provide the value directly in settings.json."
    }

    $secPass    = ConvertTo-SecureString $credPass -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($credUser, $secPass)

    $sessionParams = @{
        ComputerName = $server
        Credential   = $credential
    }
    if ($bitviseConfig.use_ssl) {
        $sessionParams.UseSSL = $true
    }

    New-PSSession @sessionParams
}

function Invoke-RemoteBitviseCommand {
    <#
    .SYNOPSIS
        Executes the provisioning script on the Bitvise server via PS Remoting.
    .DESCRIPTION
        Uses Invoke-Command -FilePath to send the local provisioning script to the
        remote machine and execute it there. No need to pre-deploy the script.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

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
    $comObject     = $bitviseConfig.com_object_name

    $baseMountPath = if ($Environment -eq "test") {
        $bitviseConfig.base_mount_path_test
    } else {
        $bitviseConfig.base_mount_path_prod
    }

    $localScript = Join-Path $PSScriptRoot "Provision-SFTPAccount.ps1"

    Write-Log "Executing provisioning script on $($Session.ComputerName) ($ProvisionAction / $Environment)"

    $output = Invoke-Command -Session $Session `
        -FilePath $localScript `
        -ArgumentList $RequestJson, $ProvisionAction, $Environment, $Password, $comObject, $baseMountPath

    # Parse the output as JSON result
    $outputStr = ($output | Out-String).Trim()

    # Extract JSON from output (the script outputs JSON at the end)
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

    # Establish PS Remoting session to Bitvise server
    $session = $null
    try {
        Write-Log "Establishing PS Remoting session to $($config.bitvise.computer_name)..."
        $session = New-BitviseSession
        Write-Log "Connected to $($session.ComputerName) via PS Remoting." "SUCCESS"
    }
    catch {
        Write-Log "Failed to connect to Bitvise server: $_" "ERROR"
        Write-Log "Ensure WinRM is enabled on $($config.bitvise.computer_name): Enable-PSRemoting -Force" "ERROR"
        return
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
                    -Session $session `
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
                -Session $session `
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
