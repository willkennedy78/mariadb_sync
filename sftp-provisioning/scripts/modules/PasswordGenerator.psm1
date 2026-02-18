<#
.SYNOPSIS
    Generates passwords based on configurable requirements.
.DESCRIPTION
    Generates secure passwords respecting customer-specified complexity requirements.
    Default: 32-character alphanumeric, no special characters, ASCII encoded.
#>

function New-SFTPPassword {
    [CmdletBinding()]
    param(
        [int]$Length = 32,
        [bool]$IncludeSpecialChars = $false,
        [bool]$IncludeUppercase = $true,
        [bool]$IncludeLowercase = $true,
        [bool]$IncludeDigits = $true,
        [string]$CustomCharset = "",
        [string]$ExcludeChars = ""
    )

    # Build character set
    if ($CustomCharset) {
        $charset = $CustomCharset
    } else {
        $charset = ""
        if ($IncludeLowercase) { $charset += "abcdefghijklmnopqrstuvwxyz" }
        if ($IncludeUppercase) { $charset += "ABCDEFGHIJKLMNOPQRSTUVWXYZ" }
        if ($IncludeDigits)    { $charset += "0123456789" }
        if ($IncludeSpecialChars) { $charset += "!@#$%^&*()-_=+[]{}|;:,.<>?" }
    }

    # Remove excluded characters
    if ($ExcludeChars) {
        foreach ($c in $ExcludeChars.ToCharArray()) {
            $charset = $charset.Replace($c.ToString(), "")
        }
    }

    if ($charset.Length -eq 0) {
        throw "Cannot generate password: character set is empty after applying restrictions."
    }

    # Use cryptographic RNG for password generation
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    $password = New-Object char[] $Length

    for ($i = 0; $i -lt $Length; $i++) {
        $rng.GetBytes($bytes)
        $index = [Math]::Abs([BitConverter]::ToInt32($bytes, 0)) % $charset.Length
        $password[$i] = $charset[$index]
    }

    $rng.Dispose()
    return [string]::new($password)
}

function ConvertTo-PasswordParams {
    <#
    .SYNOPSIS
        Parses the customer's password restriction text into structured parameters.
    .DESCRIPTION
        Takes the free-text password requirements from the form and attempts to
        extract structured parameters for password generation.
    #>
    [CmdletBinding()]
    param(
        [string]$HasRestrictions,
        [string]$RestrictionDetails,
        [hashtable]$Defaults
    )

    $params = @{
        Length             = $Defaults.length
        IncludeSpecialChars = $Defaults.use_special_chars
        IncludeUppercase   = $true
        IncludeLowercase   = $true
        IncludeDigits      = $true
        CustomCharset      = ""
        ExcludeChars       = ""
    }

    # If no restrictions, return defaults
    if (-not $HasRestrictions -or $HasRestrictions -match '(?i)(no|default|N/A|none)') {
        return $params
    }

    $text = "$HasRestrictions $RestrictionDetails".ToLower()

    # Extract length requirements
    if ($text -match '(\d+)\s*(?:char|character|length|digit|min)') {
        $requestedLength = [int]$Matches[1]
        if ($requestedLength -ge 8 -and $requestedLength -le 128) {
            $params.Length = $requestedLength
        }
    }
    if ($text -match 'min(?:imum)?\s*(\d+)') {
        $requestedLength = [int]$Matches[1]
        if ($requestedLength -ge 8 -and $requestedLength -le 128) {
            $params.Length = [Math]::Max($params.Length, $requestedLength)
        }
    }
    if ($text -match 'max(?:imum)?\s*(\d+)') {
        $requestedLength = [int]$Matches[1]
        if ($requestedLength -ge 8 -and $requestedLength -le 128) {
            $params.Length = [Math]::Min($params.Length, $requestedLength)
        }
    }

    # Detect special character requirements
    if ($text -match '(?:special|symbol|punctuation)') {
        $params.IncludeSpecialChars = $true
    }
    if ($text -match '(?:no special|no symbol|alphanumeric only|alpha-?numeric)') {
        $params.IncludeSpecialChars = $false
    }

    # Detect character exclusions
    if ($text -match 'no\s+(?:letter\s+)?[Oo]|exclude.*[Oo0lI1]|ambiguous') {
        $params.ExcludeChars = "O0lI1"
    }

    return $params
}

Export-ModuleMember -Function New-SFTPPassword, ConvertTo-PasswordParams
