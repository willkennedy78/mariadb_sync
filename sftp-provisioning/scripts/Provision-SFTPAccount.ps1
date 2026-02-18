<#
.SYNOPSIS
    Creates a Bitvise SSH Server virtual account using the BssCfg COM object.
.DESCRIPTION
    This script is designed to run ON the Bitvise SSH Server machine.
    It is deployed and invoked remotely by the pipeline orchestrator via SSH.

    It reads a JSON request file, creates the virtual account with the specified
    authentication method, IP restrictions, and mount points.

    For Bitvise SSH Server v8.xx (COM object: BssCfg815.BssCfg815).
.PARAMETER RequestJson
    JSON string containing the SFTP account request details.
.PARAMETER Action
    The action to perform: 'create', 'validate', or 'delete'.
.PARAMETER Environment
    Which environment to provision: 'test' or 'production'.
.PARAMETER Password
    The generated password for the account (passed securely).
.PARAMETER ComObjectName
    The Bitvise COM object name. Default: BssCfg815.BssCfg815
.PARAMETER BaseMountPath
    The base filesystem path for SFTP mount points.
.EXAMPLE
    .\Provision-SFTPAccount.ps1 -RequestJson '{"username":"testco_test",...}' -Action create -Environment test -Password "abc123"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RequestJson,

    [Parameter(Mandatory)]
    [ValidateSet("create", "validate", "delete")]
    [string]$Action,

    [Parameter(Mandatory)]
    [ValidateSet("test", "production")]
    [string]$Environment,

    [string]$Password = "",
    [string]$ComObjectName = "BssCfg815.BssCfg815",
    [string]$BaseMountPath = ""
)

$ErrorActionPreference = "Stop"

# ── Parse request ───────────────────────────────────────────────────────────────
$request = $RequestJson | ConvertFrom-Json

$username = if ($Environment -eq "test") { $request.username_test } else { $request.username_prod }
if (-not $username) {
    Write-Error "No username specified for environment '$Environment' in the request."
    exit 1
}

# ── Result object ───────────────────────────────────────────────────────────────
$result = @{
    success     = $false
    username    = $username
    environment = $Environment
    action      = $Action
    message     = ""
    timestamp   = (Get-Date -Format "o")
}

# ── Validate action ─────────────────────────────────────────────────────────────
if ($Action -eq "validate") {
    try {
        $cfg = New-Object -COM $ComObjectName
        $cfg.settings.Lock()
        try {
            $cfg.settings.Load()

            # Check if account already exists
            $existing = $cfg.settings.access.virtAccounts.FirstWhere1("virtAccount eq ?", $username)
            if ($existing) {
                $result.message = "Account '$username' already exists."
                $result.success = $false
            } else {
                $result.message = "Account '$username' does not exist. Ready to create."
                $result.success = $true
            }
        }
        finally {
            $cfg.settings.Unlock()
        }
    }
    catch {
        $result.message = "Validation failed: $_"
    }

    $result | ConvertTo-Json
    exit ($result.success ? 0 : 1)
}

# ── Delete action ───────────────────────────────────────────────────────────────
if ($Action -eq "delete") {
    try {
        $cfg = New-Object -COM $ComObjectName
        $cfg.settings.Lock()
        try {
            $cfg.settings.Load()

            $erased = $cfg.settings.access.virtAccounts.EraseAll("virtAccount eq ?", $username)
            if ($erased -gt 0) {
                $saveResult = $cfg.settings.Save()
                if ($saveResult.failure) {
                    throw "Save failed: $($saveResult.Describe())"
                }
                $result.success = $true
                $result.message = "Account '$username' deleted successfully."
            } else {
                $result.message = "Account '$username' not found."
                $result.success = $false
            }
        }
        finally {
            $cfg.settings.Unlock()
        }
    }
    catch {
        $result.message = "Delete failed: $_"
    }

    $result | ConvertTo-Json
    exit ($result.success ? 0 : 1)
}

# ── Create action ───────────────────────────────────────────────────────────────
try {
    Write-Host "Creating Bitvise virtual account: $username"

    $cfg = New-Object -COM $ComObjectName
    $cfg.settings.Lock()

    try {
        $cfg.settings.Load()

        # Check if account already exists
        $existing = $cfg.settings.access.virtAccounts.FirstWhere1("virtAccount eq ?", $username)
        if ($existing) {
            throw "Account '$username' already exists. Use 'delete' action first if you need to recreate."
        }

        # ── Configure the new virtual account ───────────────────────────────
        $acct = $cfg.settings.access.virtAccounts.new

        # Set account name
        $acct.virtAccount = $username

        # Set group (if configured)
        if ($request.group) {
            $acct.group = $request.group
        }

        # ── Authentication: Password ────────────────────────────────────────
        $authMethod = $request.auth_method
        if ($authMethod -eq "password" -or $authMethod -eq "both") {
            if (-not $Password) {
                throw "Password is required for auth method '$authMethod' but was not provided."
            }
            $acct.virtPassword.Set($Password)
            Write-Host "  Password authentication configured."
        }

        # ── Authentication: Public Key ──────────────────────────────────────
        if ($authMethod -eq "publickey" -or $authMethod -eq "both") {
            $publicKey = $request.public_key
            if ($publicKey) {
                # Write the public key to a temporary file for import
                $tempKeyFile = Join-Path $env:TEMP "sftp_pubkey_$username.pub"
                Set-Content -Path $tempKeyFile -Value $publicKey -Encoding ASCII

                try {
                    $acct.auth.keys.ImportFromFile($tempKeyFile)
                    Write-Host "  Public key imported successfully."
                }
                finally {
                    Remove-Item $tempKeyFile -Force -ErrorAction SilentlyContinue
                }
            } else {
                Write-Warning "Public key authentication requested but no key was provided in the request."
            }
        }

        # ── Mount Points (SFTP filesystem) ──────────────────────────────────
        $mountBase = if ($BaseMountPath) { $BaseMountPath } else { "D:\SFTP\$Environment" }
        $userDir = Join-Path $mountBase $username

        # Create the directory if it doesn't exist
        if (-not (Test-Path $userDir)) {
            New-Item -ItemType Directory -Path $userDir -Force | Out-Null
            Write-Host "  Created SFTP directory: $userDir"
        }

        # Clear default mount points and add our own
        $acct.xfer.mountPoints.Clear()

        $mp = $acct.xfer.mountPoints.new
        $mp.sfsMountPath = "/"
        $mp.realRootPath = $userDir

        # Set permissions: read, write, list, but not delete by default
        try { $mp.listAccess      = $true  } catch {}
        try { $mp.readExistAccess  = $true  } catch {}
        try { $mp.writeNewAccess   = $true  } catch {}
        try { $mp.overwriteAccess  = $true  } catch {}
        try { $mp.appendAccess     = $true  } catch {}
        try { $mp.renameAccess     = $false } catch {}
        try { $mp.deleteAccess     = $false } catch {}

        $acct.xfer.mountPoints.NewCommit()
        Write-Host "  Mount point configured: / -> $userDir"

        # ── IP Access Rules (per-account) ───────────────────────────────────
        # Note: Per-account IP rules may be at different property paths depending
        # on Bitvise version. The most common paths are checked below.
        $ipList = $request.ip_whitelist
        if ($ipList -and $ipList.Count -gt 0) {
            $validIPs = $ipList | Where-Object { $_.valid -eq $true }
            if ($validIPs.Count -gt 0) {
                Write-Host "  Configuring IP restrictions ($($validIPs.Count) entries)..."

                # Per-account IP restrictions in Bitvise v8
                # Try to access the login IP address restrictions
                try {
                    $loginAddrs = $acct.loginIPAddresses
                    if ($loginAddrs) {
                        $loginAddrs.Clear()
                        foreach ($ip in $validIPs) {
                            $rule = $loginAddrs.new
                            if ($ip.type -eq "ipv4") {
                                $rule.addressType = $cfg.enums.AddressVer6Type.ipv4
                                $rule.ipv4 = $ip.raw
                            }
                            elseif ($ip.type -eq "cidr") {
                                # For CIDR, split into address and prefix
                                $parts = $ip.raw -split '/'
                                $rule.addressType = $cfg.enums.AddressVer6Type.ipv4
                                $rule.ipv4 = $parts[0]
                                try { $rule.ipv4PrefixLen = [int]$parts[1] } catch {}
                            }
                            $rule.allowConnect = $true
                            $loginAddrs.NewCommit()
                        }

                        # Add a deny-all rule at the end
                        $denyRule = $loginAddrs.new
                        $denyRule.addressType = $cfg.enums.AddressVer6Type.anyIPv4
                        $denyRule.allowConnect = $false
                        $loginAddrs.NewCommit()

                        Write-Host "  Per-account IP restrictions configured."
                    }
                }
                catch {
                    Write-Warning "  Could not set per-account IP rules (property path may differ in your Bitvise version)."
                    Write-Warning "  Error: $_"
                    Write-Warning "  IP whitelist entries that need manual configuration:"
                    foreach ($ip in $validIPs) {
                        Write-Warning "    - $($ip.raw) ($($ip.type))"
                    }
                    # Store IP info in result for manual follow-up
                    $result["manual_ip_config_required"] = $true
                    $result["ip_entries"] = $validIPs | ForEach-Object { $_.raw }
                }
            }
        }

        # ── Commit the new account ──────────────────────────────────────────
        $cfg.settings.access.virtAccounts.NewCommit()
        Write-Host "  Virtual account entry committed."

        # ── Save settings ───────────────────────────────────────────────────
        $saveResult = $cfg.settings.Save()
        if ($saveResult.failure) {
            throw "Settings save failed: $($saveResult.Describe())"
        }

        Write-Host "  Settings saved successfully."
        $result.success = $true
        $result.message = "Account '$username' created successfully in $Environment environment."
    }
    finally {
        $cfg.settings.Unlock()
        Write-Host "  Settings unlocked."
    }
}
catch {
    $result.message = "Account creation failed: $_"
    Write-Error $result.message
}

# ── Output result ───────────────────────────────────────────────────────────────
$result | ConvertTo-Json -Depth 5
exit ($result.success ? 0 : 1)
