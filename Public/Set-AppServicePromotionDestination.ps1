function Set-AppServicePromotionDestination {
    <#
    .SYNOPSIS
        Creates or updates a named destination profile.

    .DESCRIPTION
        Saves a destination App Service (subscription, resource group, app, optional slot) under a
        name so it can be referenced with -Destination on Compare-AppServiceSetting and
        Publish-AppServiceSetting. When updating an existing profile, only the parameters you pass change.

    .PARAMETER Name
        Profile name, e.g. 'test' or 'prod'.

    .PARAMETER Subscription
        Destination subscription ID or name.

    .PARAMETER Tenant
        Optional tenant ID used when switching to the destination subscription.

    .PARAMETER ResourceGroupName
        Resource group of the destination App Service.

    .PARAMETER AppName
        Destination App Service name.

    .PARAMETER Slot
        Optional destination deployment slot. Pass an empty string or 'production' to clear.

    .PARAMETER PassThru
        Return the saved profile.

    .EXAMPLE
        Set-AppServicePromotionDestination -Name prod -Subscription 'Contoso-Prod' -ResourceGroupName 'rg-web-prod' -AppName 'contoso-web-prod' -Slot staging

    .OUTPUTS
        None, or the profile when -PassThru is specified.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string] $Name,
        [string] $Subscription,
        [string] $Tenant,
        [string] $ResourceGroupName,
        [string] $AppName,
        [AllowEmptyString()][string] $Slot,
        [switch] $PassThru
    )

    $config = Read-PromotionConfig
    $existingKey = @($config.Destinations.Keys) | Where-Object { $_ -ieq $Name } | Select-Object -First 1
    if ($existingKey) {
        $dest = $config.Destinations[$existingKey]
        $config.Destinations.Remove($existingKey)
    }
    else {
        $dest = ConvertTo-PromotionTarget -InputObject @{}
    }

    if ($PSBoundParameters.ContainsKey('Subscription'))      { $dest.Subscription = $Subscription }
    if ($PSBoundParameters.ContainsKey('Tenant'))            { $dest.Tenant = $Tenant }
    if ($PSBoundParameters.ContainsKey('ResourceGroupName')) { $dest.ResourceGroupName = $ResourceGroupName }
    if ($PSBoundParameters.ContainsKey('AppName'))           { $dest.AppName = $AppName }
    if ($PSBoundParameters.ContainsKey('Slot')) {
        $dest.Slot = if ($Slot -and $Slot -ine 'production') { $Slot } else { $null }
    }

    $missing = @('Subscription', 'ResourceGroupName', 'AppName' | Where-Object { [string]::IsNullOrWhiteSpace($dest.$_) })
    if ($missing.Count -gt 0) {
        throw "Destination profile '$Name' is missing: $($missing -join ', ')."
    }

    $config.Destinations[$Name] = $dest
    if ($PSCmdlet.ShouldProcess($Name, 'Save destination profile')) {
        Write-PromotionConfig -Config $config
    }
    if ($PassThru) { Get-AppServicePromotionDestination -Name $Name }
}
