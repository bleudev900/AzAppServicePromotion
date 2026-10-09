function Compare-AppServiceSetting {
    <#
    .SYNOPSIS
        Shows what Publish-AppServiceSetting would change on the destination App Service, without changing anything.

    .DESCRIPTION
        Reads the (edited) settings file, switches the Az context to the destination subscription,
        reads the destination's current app settings / connection strings / slot-sticky names,
        restores the previous context and returns one diff item per setting:

          Add       - in the file, not on the destination
          Change    - value, slot-setting flag or connection string type differs (see 'Changes')
          Remove    - only on the destination; would be deleted (-Mode Replace)
          Keep      - only on the destination; left untouched (-Mode Merge, the default)
          Unchanged - identical (only returned with -IncludeUnchanged)

        Values are masked unless -ShowValues is used (Key Vault references are always shown).

    .PARAMETER Path
        Path of the settings file produced by Export-AppServiceSetting.

    .PARAMETER Destination
        Name of a saved destination profile (see Set-AppServicePromotionDestination).
        Explicit parameters override the profile's values.

    .PARAMETER Subscription
        Destination subscription ID or name.

    .PARAMETER Tenant
        Destination tenant ID.

    .PARAMETER ResourceGroupName
        Destination resource group.

    .PARAMETER AppName
        Destination App Service name.

    .PARAMETER Slot
        Destination slot. Use '' or 'production' for the production slot.

    .PARAMETER Mode
        Merge (default) keeps destination-only settings; Replace removes them.

    .PARAMETER IncludeUnchanged
        Also return settings that are identical.

    .PARAMETER ShowValues
        Show values in clear text instead of masking them.

    .EXAMPLE
        Compare-AppServiceSetting -Path ./promote-prod.json -Destination prod

    .EXAMPLE
        Compare-AppServiceSetting ./promote-prod.json -Subscription 'Contoso-Prod' -ResourceGroupName rg-web-prod -AppName contoso-web-prod -Mode Replace -ShowValues | Format-Table

    .OUTPUTS
        AzAppServicePromotion.DiffItem
    #>
    [CmdletBinding()]
    [OutputType('AzAppServicePromotion.DiffItem')]
    param(
        [Parameter(Mandatory, Position = 0)][string] $Path,
        [string] $Destination,
        [string] $Subscription,
        [string] $Tenant,
        [string] $ResourceGroupName,
        [string] $AppName,
        [AllowEmptyString()][string] $Slot,
        [ValidateSet('Merge', 'Replace')][string] $Mode = 'Merge',
        [switch] $IncludeUnchanged,
        [switch] $ShowValues
    )

    $desired = Read-PromotionSettingsFile -Path $Path
    $target = Resolve-PromotionDestinationFromParameter -BoundParameters $PSBoundParameters

    $prior = Enter-PromotionSubscription -Subscription $target.Subscription -Tenant $target.Tenant
    try {
        $current = Get-PromotionAppServiceState -Target $target
    }
    finally {
        Restore-PromotionContext -Context $prior
    }

    $diff = Get-PromotionDiff -Desired $desired -Current $current -Mode $Mode
    if (-not $IncludeUnchanged) { $diff = @($diff | Where-Object { $_.Action -ne 'Unchanged' }) }
    Get-PromotionDisplayDiff -Diff $diff -ShowValues:$ShowValues
}
