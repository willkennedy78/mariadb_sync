<#
.SYNOPSIS
    Parses and normalizes Microsoft Forms response data into structured SFTP request objects.
.DESCRIPTION
    Takes raw form response JSON (from Power Automate or API) and produces a normalized
    request object ready for the approval and provisioning pipeline.
#>

function Repair-MalformedJson {
    <#
    .SYNOPSIS
        Repairs malformed JSON produced by Power Automate (unquoted values, markdown fences).
    .DESCRIPTION
        Power Automate's "Compose" action can produce pseudo-JSON where string values
        are not quoted. This function fixes the content so ConvertFrom-Json can parse it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    # Strip markdown code fences (```json ... ```)
    $Text = $Text -replace '^\s*```\w*\s*', ''
    $Text = $Text -replace '\s*```\s*$', ''
    $Text = $Text.Trim()

    $lines = $Text -split "`n"
    $result = [System.Collections.ArrayList]::new()

    foreach ($line in $lines) {
        $trimmed = $line.TrimEnd()

        # Match lines like:  "key": value,  or  "key": value
        if ($trimmed -match '^(\s*"[^"]+")\s*:\s*(.*)$') {
            $keyPart = $Matches[1]
            $valuePart = $Matches[2].TrimEnd()

            # Detect and strip trailing comma
            $trailingComma = ''
            if ($valuePart -match ',\s*$') {
                $trailingComma = ','
                $valuePart = ($valuePart -replace ',\s*$', '').TrimEnd()
            }

            $needsQuoting = $false

            if ($valuePart -eq '' -or $valuePart -eq $null) {
                # Empty value: "key":  or "key": ,
                $needsQuoting = $true
                $valuePart = ''
            }
            elseif ($valuePart -match '^\d+(\.\d+)?$') {
                # Number - valid as-is
            }
            elseif ($valuePart -eq 'true' -or $valuePart -eq 'false' -or $valuePart -eq 'null') {
                # Boolean/null - valid as-is
            }
            elseif ($valuePart -match '^".*"$') {
                # Already quoted - valid as-is
            }
            elseif ($valuePart -match '^\[' -or $valuePart -match '^\{') {
                # Array or object start - valid as-is
            }
            else {
                $needsQuoting = $true
            }

            if ($needsQuoting) {
                # Escape backslashes and double quotes inside the value
                $escaped = $valuePart -replace '\\', '\\' -replace '"', '\"'
                $line = "${keyPart}: `"${escaped}`"${trailingComma}"
            }
        }

        $null = $result.Add($line)
    }

    return $result -join "`n"
}

function ConvertTo-SFTPRequest {
    <#
    .SYNOPSIS
        Converts a raw form response into a normalized SFTP provisioning request.
    .PARAMETER RawResponse
        The raw JSON object from the form response.
    .PARAMETER FieldMapping
        Hashtable mapping internal field names to form question text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$RawResponse,

        [Parameter(Mandatory)]
        [hashtable]$FieldMapping
    )

    # Extract fields using the mapping - try both direct property names and mapped names
    $request = [PSCustomObject]@{
        id                  = $(if ($RawResponse.id) { $RawResponse.id } elseif ($RawResponse.responseId) { $RawResponse.responseId } else { [guid]::NewGuid().ToString() })
        submitted_at        = $(if ($RawResponse.submitDate) { $RawResponse.submitDate } elseif ($RawResponse.submitted_at) { $RawResponse.submitted_at } else { Get-Date -Format "o" })
        responder_email     = $(if ($RawResponse.responder) { $RawResponse.responder } elseif ($RawResponse.responderEmail) { $RawResponse.responderEmail } else { "unknown" })
        responder_name      = $(if ($RawResponse.responderName) { $RawResponse.responderName } else { "" })

        # Core fields
        customer_name       = Get-FieldValue $RawResponse $FieldMapping.customer_name
        requester_name      = Get-FieldValue $RawResponse $FieldMapping.requester_name
        environment         = Resolve-Environment (Get-FieldValue $RawResponse $FieldMapping.environment)
        auth_method         = Resolve-AuthMethod (Get-FieldValue $RawResponse $FieldMapping.auth_method)
        password_restrictions = Get-FieldValue $RawResponse $FieldMapping.password_restrictions
        password_requirements_detail = Get-FieldValue $RawResponse $FieldMapping.password_requirements_detail
        public_key          = Get-FieldValue $RawResponse $FieldMapping.public_key
        delivery_method     = Resolve-DeliveryMethod (Get-FieldValue $RawResponse $FieldMapping.delivery_method)
        recipient_email     = Get-FieldValue $RawResponse $FieldMapping.recipient_email
        recipient_phone     = Get-FieldValue $RawResponse $FieldMapping.recipient_phone
        ip_whitelist        = Parse-IPWhitelist (Get-FieldValue $RawResponse $FieldMapping.ip_whitelist)

        # Metadata
        status              = "pending"
        created_at          = (Get-Date -Format "o")
        reviewed_by         = ""
        reviewed_at         = ""
        provisioned_at      = ""
        notes               = ""

        # Derived fields (populated during provisioning)
        username_test       = ""
        username_prod       = ""
        password_generated  = $false
    }

    # Generate username from customer name
    $sanitized = ConvertTo-SFTPUsername $request.customer_name
    $envs = $request.environment
    if ($envs -contains "test" -or $envs -contains "both") {
        $request.username_test = "${sanitized}_test"
    }
    if ($envs -contains "production" -or $envs -contains "both") {
        $request.username_prod = "${sanitized}_prod"
    }

    return $request
}

function Get-FieldValue {
    <#
    .SYNOPSIS
        Extracts a field value from the response object, trying multiple strategies.
    #>
    param(
        [PSCustomObject]$Response,
        [string]$FieldName
    )

    if (-not $FieldName) { return "" }

    # Strategy 1: Direct property name match
    $value = $Response.PSObject.Properties | Where-Object { $_.Name -eq $FieldName } | Select-Object -First 1
    if ($value) { $v = $value.Value; if ($null -eq $v) { $v = "" }; return $v.ToString().Trim() }

    # Strategy 2: Case-insensitive partial match (form questions can be truncated)
    $value = $Response.PSObject.Properties | Where-Object {
        $_.Name -like "*$($FieldName.Substring(0, [Math]::Min(40, $FieldName.Length)))*"
    } | Select-Object -First 1
    if ($value) { $v = $value.Value; if ($null -eq $v) { $v = "" }; return $v.ToString().Trim() }

    # Strategy 3: Check nested 'answers' array (from Forms API format)
    if ($Response.answers) {
        $answers = if ($Response.answers -is [string]) {
            ConvertFrom-Json -InputObject $Response.answers
        } else {
            $Response.answers
        }
        foreach ($answer in $answers) {
            if ($answer.questionId -and $answer.answer1) {
                # This requires a questionId-to-text mapping which we'd build separately
                # For Power Automate output, fields are already flattened
            }
        }
    }

    return ""
}

function Resolve-Environment {
    param([string]$Value)
    $v = $Value.ToLower().Trim()
    switch -Wildcard ($v) {
        "*both*"       { return @("test", "production") }
        "*test*"       { return @("test") }
        "*prod*"       { return @("production") }
        "*uat*"        { return @("test") }
        "*live*"       { return @("production") }
        default        { return @($v) }
    }
}

function Resolve-AuthMethod {
    param([string]$Value)
    $v = $Value.ToLower().Trim()
    switch -Wildcard ($v) {
        "*both*"       { return "both" }
        "*key and password*"  { return "both" }
        "*password and*key*"  { return "both" }
        "*combined*"   { return "both" }
        "*key*"        { return "publickey" }
        "*public*"     { return "publickey" }
        "*password*"   { return "password" }
        default        { return "password" }
    }
}

function Resolve-DeliveryMethod {
    param([string]$Value)
    $v = $Value.ToLower().Trim()
    switch -Wildcard ($v) {
        "*sms*"        { return "sms" }
        "*whatsapp*"   { return "whatsapp" }
        "*telegram*"   { return "telegram" }
        "*email*"      { return "email" }
        default        { return $v }
    }
}

function Parse-IPWhitelist {
    <#
    .SYNOPSIS
        Parses the IP whitelist field into an array of structured IP entries.
    .DESCRIPTION
        Handles individual IPs, CIDR ranges, and space/comma/newline-separated lists.
    #>
    param([string]$Value)

    if (-not $Value -or $Value.Trim() -eq "") { return @() }

    # Split on common delimiters: comma, semicolon, newline, space (but not within CIDR notation)
    $raw = $Value -split '[,;\n]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    # Further split space-separated entries (but preserve CIDR notation)
    $entries = @()
    foreach ($item in $raw) {
        $parts = $item -split '\s+' | Where-Object { $_ -ne "" }
        $entries += $parts
    }

    $result = @()
    foreach ($entry in $entries) {
        $entry = $entry.Trim()
        if (-not $entry) { continue }

        $ipEntry = [PSCustomObject]@{
            raw    = $entry
            type   = "unknown"
            valid  = $false
        }

        if ($entry -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$') {
            # CIDR notation (e.g., 5.6.7.8/32)
            $ipEntry.type = "cidr"
            $ipEntry.valid = $true
        }
        elseif ($entry -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            # Single IPv4 address
            $ipEntry.type = "ipv4"
            $ipEntry.valid = $true
        }
        elseif ($entry -match '^[0-9a-fA-F:]+$') {
            # IPv6 address
            $ipEntry.type = "ipv6"
            $ipEntry.valid = $true
        }
        elseif ($entry -match '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\s*-\s*\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') {
            # IP range
            $ipEntry.type = "range"
            $ipEntry.valid = $true
        }

        $result += $ipEntry
    }

    return $result
}

function ConvertTo-SFTPUsername {
    <#
    .SYNOPSIS
        Converts a customer name into a valid SFTP username.
    .DESCRIPTION
        Sanitizes the customer name for use as a Bitvise virtual account name.
        Removes special characters, converts to lowercase, replaces spaces with underscores.
    #>
    param([string]$CustomerName)

    if (-not $CustomerName) { return "unknown_customer" }

    $username = $CustomerName.ToLower().Trim()
    # Replace spaces and common separators with underscores
    $username = $username -replace '[\s\-\.]+', '_'
    # Remove anything that isn't alphanumeric or underscore
    $username = $username -replace '[^a-z0-9_]', ''
    # Remove consecutive underscores
    $username = $username -replace '_{2,}', '_'
    # Trim underscores from start/end
    $username = $username.Trim('_')
    # Ensure it doesn't start with a number
    if ($username -match '^\d') { $username = "sftp_$username" }
    # Truncate to reasonable length
    if ($username.Length -gt 30) { $username = $username.Substring(0, 30).TrimEnd('_') }

    return $username
}

Export-ModuleMember -Function Repair-MalformedJson, ConvertTo-SFTPRequest, ConvertTo-SFTPUsername, Parse-IPWhitelist, Resolve-Environment, Resolve-AuthMethod
