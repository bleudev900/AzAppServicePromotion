function Get-PromotionConfigPath {
    <#
    .SYNOPSIS
        Returns the path of the per-user configuration file.
    .DESCRIPTION
        Uses $env:AZAPPSERVICEPROMOTION_CONFIG when set, otherwise
        <user profile>/.azappservicepromotion/config.json (cross-platform).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:AZAPPSERVICEPROMOTION_CONFIG)) {
        return $env:AZAPPSERVICEPROMOTION_CONFIG
    }
    $userHome = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrWhiteSpace($userHome)) { $userHome = $HOME }
    return (Join-Path -Path (Join-Path -Path $userHome -ChildPath '.azappservicepromotion') -ChildPath 'config.json')
}

function ConvertTo-PromotionTarget {
    <#
    .SYNOPSIS
        Normalises a deserialised target object into a PSCustomObject with known properties.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()] $InputObject)

    if ($null -eq $InputObject) { return $null }
    $get = {
        param($o, $n)
        if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n)) { return $o[$n] } else { return $null } }
        $p = $o.PSObject.Properties[$n]
        if ($p) { return $p.Value } else { return $null }
    }
    [pscustomobject]@{
        Subscription      = [string](& $get $InputObject 'Subscription')
        Tenant            = [string](& $get $InputObject 'Tenant')
        ResourceGroupName = [string](& $get $InputObject 'ResourceGroupName')
        AppName           = [string](& $get $InputObject 'AppName')
        Slot              = [string](& $get $InputObject 'Slot')
    }
}

function Read-PromotionConfig {
    <#
    .SYNOPSIS
        Reads the configuration file and returns a normalised object (never $null).
    #>
    [CmdletBinding()]
    param()

    $path = Get-PromotionConfigPath
    $config = [pscustomobject]@{
        Source          = $null
        ExportDirectory = $null
        Destinations    = [ordered]@{}
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $config }

    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $config }
    try {
        $json = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Configuration file '$path' is not valid JSON: $($_.Exception.Message)"
    }

    if ($json.PSObject.Properties['Source'] -and $json.Source) {
        $config.Source = ConvertTo-PromotionTarget -InputObject $json.Source
    }
    if ($json.PSObject.Properties['ExportDirectory']) {
        $config.ExportDirectory = [string]$json.ExportDirectory
    }
    if ($json.PSObject.Properties['Destinations'] -and $json.Destinations) {
        foreach ($p in $json.Destinations.PSObject.Properties) {
            $config.Destinations[$p.Name] = ConvertTo-PromotionTarget -InputObject $p.Value
        }
    }
    return $config
}

function Write-PromotionConfig {
    <#
    .SYNOPSIS
        Persists the configuration object to the per-user configuration file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Config)

    $path = Get-PromotionConfigPath
    $dir = Split-Path -Path $path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        $null = New-Item -Path $dir -ItemType Directory -Force
    }
    $doc = [ordered]@{
        Source          = $Config.Source
        ExportDirectory = $Config.ExportDirectory
        Destinations    = $Config.Destinations
    }
    Write-Utf8File -Path $path -Content ($doc | ConvertTo-Json -Depth 10)
}

function Write-Utf8File {
    <#
    .SYNOPSIS
        Writes text as UTF-8 without BOM (consistent across Windows PowerShell and PowerShell 7).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Content
    )
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    [System.IO.File]::WriteAllText($full, $Content, (New-Object System.Text.UTF8Encoding($false)))
}
