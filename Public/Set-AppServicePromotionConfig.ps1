function Set-AppServicePromotionConfig {
    <#
    .SYNOPSIS
        Saves the source App Service (and optional export directory) to the per-user configuration file.

    .DESCRIPTION
        Stores the source subscription, resource group, App Service name and optional deployment slot
        that Export-AppServiceSetting reads from by default. Values are written to
        $HOME/.azappservicepromotion/config.json (override with $env:AZAPPSERVICEPROMOTION_CONFIG).
        Only the parameters you pass are updated; other saved values are kept.

    .PARAMETER Subscription
        Source subscription ID or name.

    .PARAMETER Tenant
        Optional tenant ID used when switching to the source subscription.

    .PARAMETER ResourceGroupName
        Resource group of the source App Service.

    .PARAMETER AppName
        Name of the source App Service.

    .PARAMETER Slot
        Optional deployment slot of the source App Service. Pass an empty string or 'production' to clear.

    .PARAMETER ExportDirectory
        Optional default directory for exported settings files. Pass an empty string to clear.

    .PARAMETER PassThru
        Return the resulting configuration.

    .EXAMPLE
        Set-AppServicePromotionConfig -Subscription 'Contoso-Dev' -ResourceGroupName 'rg-web-dev' -AppName 'contoso-web-dev'

        Saves the source App Service used by Export-AppServiceSetting.

    .EXAMPLE
        Set-AppServicePromotionConfig -Slot staging -ExportDirectory '~/promotions'

        Updates only the slot and export directory.

    .OUTPUTS
        None, or the configuration object when -PassThru is specified.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string] $Subscription,
        [string] $Tenant,
        [string] $ResourceGroupName,
        [string] $AppName,
        [AllowEmptyString()][string] $Slot,
        [AllowEmptyString()][string] $ExportDirectory,
        [switch] $PassThru
    )

    $config = Read-PromotionConfig
    $source = $config.Source
    if (-not $source) { $source = ConvertTo-PromotionTarget -InputObject @{} }

    if ($PSBoundParameters.ContainsKey('Subscription'))      { $source.Subscription = $Subscription }
    if ($PSBoundParameters.ContainsKey('Tenant'))            { $source.Tenant = $Tenant }
    if ($PSBoundParameters.ContainsKey('ResourceGroupName')) { $source.ResourceGroupName = $ResourceGroupName }
    if ($PSBoundParameters.ContainsKey('AppName'))           { $source.AppName = $AppName }
    if ($PSBoundParameters.ContainsKey('Slot')) {
        $source.Slot = if ($Slot -and $Slot -ine 'production') { $Slot } else { $null }
    }
    $config.Source = $source

    if ($PSBoundParameters.ContainsKey('ExportDirectory')) {
        $config.ExportDirectory = if ($ExportDirectory) { $ExportDirectory } else { $null }
    }

    $path = Get-PromotionConfigPath
    if ($PSCmdlet.ShouldProcess($path, 'Save source App Service configuration')) {
        Write-PromotionConfig -Config $config
    }
    if ($PassThru) { Get-AppServicePromotionConfig }
}
