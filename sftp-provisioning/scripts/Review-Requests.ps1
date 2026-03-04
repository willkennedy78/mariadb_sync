<#
.SYNOPSIS
    Interactive CLI for reviewing and approving/rejecting pending SFTP account requests.
.DESCRIPTION
    Reads JSON files from the queue/pending directory, displays the details of each
    request, and allows the admin to approve or reject. Approved requests are moved
    to queue/approved for provisioning. Rejected requests are moved to queue/rejected.
.PARAMETER ConfigPath
    Path to the settings.json configuration file.
.EXAMPLE
    .\Review-Requests.ps1
    .\Review-Requests.ps1 -ConfigPath ..\config\settings.json
#>

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "..\config\settings.json")
)

$ErrorActionPreference = "Stop"
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
foreach ($section in @('general', 'form_field_mapping')) {
    if (-not $config.$section) {
        throw "Configuration '$ConfigPath' is missing required section: '$section'"
    }
}
$baseDir   = Split-Path (Split-Path $ConfigPath -Parent) -Parent
$queueBase = Join-Path $baseDir $config.general.queue_path

$pendingPath  = Join-Path $queueBase "pending"
$approvedPath = Join-Path $queueBase "approved"
$rejectedPath = Join-Path $queueBase "rejected"

foreach ($dir in @($pendingPath, $approvedPath, $rejectedPath)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# ── Display functions ───────────────────────────────────────────────────────────
function Show-RequestSummary {
    param([PSCustomObject]$Request, [int]$Index, [int]$Total)

    $divider = "=" * 70
    Write-Host ""
    Write-Host $divider -ForegroundColor Cyan
    Write-Host " Request $Index of $Total" -ForegroundColor Cyan
    Write-Host $divider -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  Customer:        " -NoNewline; Write-Host "$($Request.customer_name)" -ForegroundColor White
    Write-Host "  Requester:       " -NoNewline; Write-Host "$($Request.requester_name)" -ForegroundColor White
    Write-Host "  Submitted:       " -NoNewline; Write-Host "$($Request.submitted_at)" -ForegroundColor Gray
    Write-Host ""

    # Environment
    $envDisplay = ($Request.environment -join ", ").ToUpper()
    Write-Host "  Environment:     " -NoNewline; Write-Host "$envDisplay" -ForegroundColor Yellow

    # Auth method
    $authColor = switch ($Request.auth_method) {
        "both"      { "Green" }
        "publickey" { "Cyan" }
        "password"  { "Yellow" }
        default     { "White" }
    }
    Write-Host "  Auth Method:     " -NoNewline; Write-Host "$($Request.auth_method)" -ForegroundColor $authColor

    # Password requirements
    if ($Request.password_restrictions) {
        Write-Host "  Password Reqs:   " -NoNewline; Write-Host "$($Request.password_restrictions)" -ForegroundColor Gray
    }
    if ($Request.password_requirements_detail) {
        Write-Host "  Password Detail:  " -NoNewline; Write-Host "$($Request.password_requirements_detail)" -ForegroundColor Gray
    }

    # Public key
    if ($Request.public_key) {
        $keyPreview = if ($Request.public_key.Length -gt 60) {
            $Request.public_key.Substring(0, 60) + "..."
        } else { $Request.public_key }
        Write-Host "  Public Key:      " -NoNewline; Write-Host "$keyPreview" -ForegroundColor Gray
    }

    Write-Host ""

    # Credential delivery
    Write-Host "  Delivery Method: " -NoNewline; Write-Host "$($Request.delivery_method)" -ForegroundColor White
    Write-Host "  Recipient Email: " -NoNewline; Write-Host "$($Request.recipient_email)" -ForegroundColor White
    Write-Host "  Recipient Phone: " -NoNewline; Write-Host "$($Request.recipient_phone)" -ForegroundColor White

    Write-Host ""

    # IP whitelist
    if ($Request.ip_whitelist -and $Request.ip_whitelist.Count -gt 0) {
        Write-Host "  IP Whitelist:" -ForegroundColor White
        foreach ($ip in $Request.ip_whitelist) {
            $validColor = if ($ip.valid) { "Green" } else { "Red" }
            Write-Host "    - $($ip.raw) " -NoNewline
            Write-Host "[$($ip.type)]" -ForegroundColor $validColor
        }
    } else {
        Write-Host "  IP Whitelist:    " -NoNewline; Write-Host "NONE SPECIFIED" -ForegroundColor Red
    }

    Write-Host ""

    # Proposed usernames
    if ($Request.username_test) {
        Write-Host "  Username (Test): " -NoNewline; Write-Host "$($Request.username_test)" -ForegroundColor Green
    }
    if ($Request.username_prod) {
        Write-Host "  Username (Prod): " -NoNewline; Write-Host "$($Request.username_prod)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host $divider -ForegroundColor Cyan
}

function Get-AdminDecision {
    while ($true) {
        Write-Host ""
        Write-Host "  [A] Approve   [R] Reject   [E] Edit username   [S] Skip   [Q] Quit" -ForegroundColor Yellow
        Write-Host ""
        $choice = Read-Host "  Decision"

        switch ($choice.ToUpper()) {
            "A" { return "approve" }
            "R" { return "reject" }
            "E" { return "edit" }
            "S" { return "skip" }
            "Q" { return "quit" }
            default {
                Write-Host "  Invalid choice. Please enter A, R, E, S, or Q." -ForegroundColor Red
            }
        }
    }
}

function Edit-Username {
    param([PSCustomObject]$Request)

    if ($Request.username_test) {
        $newTest = Read-Host "  New test username (current: $($Request.username_test), Enter to keep)"
        if ($newTest) { $Request.username_test = $newTest }
    }
    if ($Request.username_prod) {
        $newProd = Read-Host "  New prod username (current: $($Request.username_prod), Enter to keep)"
        if ($newProd) { $Request.username_prod = $newProd }
    }

    return $Request
}

# ── Main review loop ────────────────────────────────────────────────────────────
function Invoke-Review {
    $fieldMapping = @{}
    foreach ($prop in $config.form_field_mapping.PSObject.Properties) {
        $fieldMapping[$prop.Name] = $prop.Value
    }

    # Get pending files
    $pendingFiles = Get-ChildItem -Path $pendingPath -Filter "*.json" -ErrorAction SilentlyContinue |
        Sort-Object CreationTime

    if ($pendingFiles.Count -eq 0) {
        Write-Host ""
        Write-Host "  No pending requests to review." -ForegroundColor Green
        Write-Host "  Run Sync-PendingRequests.ps1 to check for new form responses." -ForegroundColor Gray
        Write-Host ""
        return
    }

    Write-Host ""
    Write-Host "  Found $($pendingFiles.Count) pending request(s) to review." -ForegroundColor Cyan
    Write-Host ""

    $currentIndex = 0

    foreach ($file in $pendingFiles) {
        $currentIndex++

        try {
            $rawData = ConvertFrom-Json -InputObject (Get-Content $file.FullName -Raw -Encoding UTF8)

            # Check if already parsed (has 'status' field) or needs parsing
            if ($rawData.status -and $rawData.customer_name) {
                $request = $rawData
            } else {
                $request = ConvertTo-SFTPRequest -RawResponse $rawData -FieldMapping $fieldMapping
            }
        }
        catch {
            Write-Host "  ERROR: Failed to parse $($file.Name): $_" -ForegroundColor Red
            continue
        }

        $reviewing = $true
        while ($reviewing) {
            Show-RequestSummary -Request $request -Index $currentIndex -Total $pendingFiles.Count
            $decision = Get-AdminDecision

            switch ($decision) {
                "approve" {
                    $request.status      = "approved"
                    $request.reviewed_by  = $(if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { "admin" })
                    $request.reviewed_at  = (Get-Date -Format "o")

                    $request | ConvertTo-Json -Depth 10 |
                        Set-Content -Path (Join-Path $approvedPath $file.Name) -Encoding UTF8

                    Remove-Item $file.FullName -Force
                    Write-Host "  APPROVED - moved to approved queue." -ForegroundColor Green
                    $reviewing = $false
                }
                "reject" {
                    $reason = Read-Host "  Rejection reason"
                    $request.status      = "rejected"
                    $request.reviewed_by  = $(if ($env:USERNAME) { $env:USERNAME } elseif ($env:USER) { $env:USER } else { "admin" })
                    $request.reviewed_at  = (Get-Date -Format "o")
                    $request.notes        = "Rejected: $reason"

                    $request | ConvertTo-Json -Depth 10 |
                        Set-Content -Path (Join-Path $rejectedPath $file.Name) -Encoding UTF8

                    Remove-Item $file.FullName -Force
                    Write-Host "  REJECTED - moved to rejected queue." -ForegroundColor Red
                    $reviewing = $false
                }
                "edit" {
                    $request = Edit-Username -Request $request
                    Write-Host "  Username updated. Showing request again..." -ForegroundColor Yellow
                    # Loop continues, shows updated request
                }
                "skip" {
                    Write-Host "  Skipped." -ForegroundColor Gray
                    $reviewing = $false
                }
                "quit" {
                    Write-Host ""
                    Write-Host "  Review session ended." -ForegroundColor Cyan
                    return
                }
            }
        }
    }

    # Summary
    $approvedCount = (Get-ChildItem -Path $approvedPath -Filter "*.json" -ErrorAction SilentlyContinue).Count
    Write-Host ""
    Write-Host "  Review complete. $approvedCount request(s) in the approved queue." -ForegroundColor Cyan
    if ($approvedCount -gt 0) {
        Write-Host "  Run Invoke-Pipeline.ps1 -Action Provision to create the SFTP accounts." -ForegroundColor Yellow
    }
    Write-Host ""
}

# ── Execute ─────────────────────────────────────────────────────────────────────
Invoke-Review
