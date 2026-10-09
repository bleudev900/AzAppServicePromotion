function Export-AppServiceSetting {
    <#
    .SYNOPSIS
        Exports the source App Service's app settings and connection strings to an editable JSON file.

    .DESCRIPTION
        Switches the Az context to the source subscription, reads the app settings (environment
        variables), connection strings and slot-sticky ("deployment slot setting") flags of the source
        App Service (or slot), writes them to a JSON file, and restores your previous Az context.

        The source defaults to the one saved with Set-AppServicePromotionConfig; any explicit
        parameter overrides the saved value.

        WARNING: the exported file contains secrets in plain text (Key Vault references are exported
        as-is, i.e. as @Microsoft.KeyVault(...) references, not resolved). Do not commit it; add it to .gitignore.

        File layout:
          {
            "schemaVersion": 1,
            "metadata": { "exportedAtUtc": "...", "exportedBy": "...", "source": { ... }, "warning": "..." },
            "appSettings": [ { "name": "...", "value": "...", "slotSetting": false } ],
            "connectionStrings": [ { "name": "...", "value": "...", "type": "SQLAzure", "slotSetting": false } ]
          }

    .PARAMETER Path
        Output file path. Defaults to <ExportDirectory or current directory>/<app>[-<slot>]-settings-<timestamp>.json.

    .PARAMETER Subscription
        Overrides the saved source subscription (ID or name).

    .PARAMETER Tenant
        Overrides the saved source tenant.

    .PARAMETER ResourceGroupName
        Overrides the saved source resource group.

    .PARAMETER AppName
        Overrides the saved source App Service name.

    .PARAMETER Slot
        Overrides the saved source slot. Use '' or 'production' for the production slot.

    .PARAMETER ExcludeSetting
        Wildcard patterns of app setting / connection string names to leave out of the export
        (e.g. 'WEBSITE_*', 'APPINSIGHTS_*').

    .PARAMETER Force
        Overwrite the output file if it already exists.

    .EXAMPLE
        Export-AppServiceSetting -Path ./promote-prod.json

        Exports the configured source App Service settings to ./promote-prod.json.

    .EXAMPLE
        Export-AppServiceSetting -Slot staging -ExcludeSetting 'WEBSITE_*' -Force

    .OUTPUTS
        System.IO.FileInfo of the written file.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Position = 0)][string] $Path,
        [string] $Subscription,
        [string] $Tenant,
        [string] $ResourceGroupName,
        [string] $AppName,
        [AllowEmptyString()][string] $Slot,
        [SupportsWildcards()][string[]] $ExcludeSetting,
        [switch] $Force
    )

    $config = Read-PromotionConfig
    $resolveParams = @{ Base = $config.Source; Role = 'source' }
    foreach ($n in 'Subscription', 'Tenant', 'ResourceGroupName', 'AppName') {
        if ($PSBoundParameters.ContainsKey($n)) { $resolveParams[$n] = $PSBoundParameters[$n] }
    }
    if ($PSBoundParameters.ContainsKey('Slot')) { $resolveParams['Slot'] = $Slot; $resolveParams['SlotSpecified'] = $true }
    $source = Resolve-PromotionTarget @resolveParams

    if (-not $Path) {
        $dir = if ($config.ExportDirectory) { $config.ExportDirectory } else { (Get-Location).ProviderPath }
        $leaf = $source.AppName
        if ($source.Slot) { $leaf += "-$($source.Slot)" }
        $Path = Join-Path -Path $dir -ChildPath ("{0}-settings-{1}.json" -f $leaf, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ((Test-Path -LiteralPath $fullPath) -and -not $Force) {
        throw "File '$fullPath' already exists. Use -Force to overwrite."
    }
    $parent = Split-Path -Path $fullPath -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        $null = New-Item -Path $parent -ItemType Directory -Force
    }

    $prior = Enter-PromotionSubscription -Subscription $source.Subscription -Tenant $source.Tenant
    try {
        $context = Get-AzContext
        $state = Get-PromotionAppServiceState -Target $source
    }
    finally {
        Restore-PromotionContext -Context $prior
    }

    $isExcluded = {
        param($name)
        foreach ($pattern in @($ExcludeSetting)) { if ($pattern -and $name -like $pattern) { return $true } }
        return $false
    }
    $appSettings = @($state.AppSettings | Where-Object { -not (& $isExcluded $_.name) })
    $connectionStrings = @($state.ConnectionStrings | Where-Object { -not (& $isExcluded $_.name) })

    $subscriptionId = $source.Subscription
    $subscriptionName = $null
    if ($context -and $context.PSObject.Properties['Subscription'] -and $context.Subscription) {
        if ($context.Subscription.PSObject.Properties['Id'])   { $subscriptionId = $context.Subscription.Id }
        if ($context.Subscription.PSObject.Properties['Name']) { $subscriptionName = $context.Subscription.Name }
    }
    $exportedBy = $null
    if ($context -and $context.PSObject.Properties['Account'] -and $context.Account) { $exportedBy = [string]$context.Account }

    $doc = [ordered]@{
        schemaVersion     = $script:SettingsFileSchemaVersion
        metadata          = [ordered]@{
            exportedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
            exportedBy    = $exportedBy
            source        = [ordered]@{
                subscriptionId    = $subscriptionId
                subscriptionName  = $subscriptionName
                resourceGroupName = $source.ResourceGroupName
                appName           = $source.AppName
                slot              = $source.Slot
            }
            excluded      = $(if ($ExcludeSetting) { @($ExcludeSetting) } else { @() })
            warning       = 'This file contains secrets in plain text. Do not commit it to source control.'
        }
        appSettings       = $appSettings
        connectionStrings = $connectionStrings
    }

    Write-Utf8File -Path $fullPath -Content ($doc | ConvertTo-Json -Depth 10)
    Write-Verbose "Exported $($appSettings.Count) app setting(s) and $($connectionStrings.Count) connection string(s) from $(Format-PromotionTarget -Target $source)."
    Write-Warning "'$fullPath' contains secrets in plain text (Key Vault references are kept as references). Do not commit it; add it (or a pattern such as '*-settings-*.json') to .gitignore and delete it when done."

    Get-Item -LiteralPath $fullPath
}
