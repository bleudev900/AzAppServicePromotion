$script:ValidConnectionStringTypes = @(
    'MySql', 'SQLServer', 'SQLAzure', 'Custom', 'NotificationHub', 'ServiceBus',
    'EventHub', 'ApiHub', 'DocDb', 'RedisCache', 'PostgreSQL'
)

$script:SettingsFileSchemaVersion = 1

function Read-PromotionSettingsFile {
    <#
    .SYNOPSIS
        Reads and validates an exported (and possibly edited) settings file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Settings file '$Path' was not found."
    }
    try {
        $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Settings file '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $appSettings = New-Object System.Collections.Generic.List[object]
    $connectionStrings = New-Object System.Collections.Generic.List[object]

    $rawApp = @()
    if ($doc.PSObject.Properties['appSettings'] -and $null -ne $doc.appSettings) { $rawApp = @($doc.appSettings) }
    $rawConn = @()
    if ($doc.PSObject.Properties['connectionStrings'] -and $null -ne $doc.connectionStrings) { $rawConn = @($doc.connectionStrings) }

    $seen = @{}
    $i = 0
    foreach ($s in $rawApp) {
        $i++
        if ($null -eq $s -or -not $s.PSObject.Properties['name'] -or [string]::IsNullOrWhiteSpace([string]$s.name)) {
            $errors.Add("appSettings[$i]: 'name' is required."); continue
        }
        $name = [string]$s.name
        if ($seen.ContainsKey($name)) { $errors.Add("appSettings: duplicate name '$name' (names are case-insensitive)."); continue }
        $seen[$name] = $true
        $value = if ($s.PSObject.Properties['value'] -and $null -ne $s.value) { [string]$s.value } else { '' }
        $sticky = $false
        if ($s.PSObject.Properties['slotSetting'] -and $null -ne $s.slotSetting) { $sticky = [bool]$s.slotSetting }
        $appSettings.Add([pscustomobject][ordered]@{ name = $name; value = $value; slotSetting = $sticky })
    }

    $seen = @{}
    $i = 0
    foreach ($c in $rawConn) {
        $i++
        if ($null -eq $c -or -not $c.PSObject.Properties['name'] -or [string]::IsNullOrWhiteSpace([string]$c.name)) {
            $errors.Add("connectionStrings[$i]: 'name' is required."); continue
        }
        $name = [string]$c.name
        if ($seen.ContainsKey($name)) { $errors.Add("connectionStrings: duplicate name '$name' (names are case-insensitive)."); continue }
        $seen[$name] = $true
        $value = if ($c.PSObject.Properties['value'] -and $null -ne $c.value) { [string]$c.value } else { '' }
        $type = if ($c.PSObject.Properties['type'] -and -not [string]::IsNullOrWhiteSpace([string]$c.type)) { [string]$c.type } else { 'Custom' }
        $match = $script:ValidConnectionStringTypes | Where-Object { $_ -ieq $type } | Select-Object -First 1
        if (-not $match) {
            $errors.Add("connectionStrings '$name': invalid type '$type'. Valid types: $($script:ValidConnectionStringTypes -join ', ').")
            continue
        }
        $sticky = $false
        if ($c.PSObject.Properties['slotSetting'] -and $null -ne $c.slotSetting) { $sticky = [bool]$c.slotSetting }
        $connectionStrings.Add([pscustomobject][ordered]@{ name = $name; value = $value; type = $match; slotSetting = $sticky })
    }

    if ($errors.Count -gt 0) {
        throw "Settings file '$Path' is invalid:`n - $($errors -join "`n - ")"
    }

    $metadata = $null
    if ($doc.PSObject.Properties['metadata']) { $metadata = $doc.metadata }

    [pscustomobject]@{
        Path              = $Path
        Metadata          = $metadata
        AppSettings       = $appSettings.ToArray()
        ConnectionStrings = $connectionStrings.ToArray()
    }
}

function Hide-PromotionValue {
    <#
    .SYNOPSIS
        Masks a setting value for display. Key Vault references are shown as-is.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -eq '') { return '' }
    if ($Value -like '@Microsoft.KeyVault(*') { return $Value }
    return "******** ($($Value.Length) chars)"
}
