function Get-AppServicePromotionDestination {
    <#
    .SYNOPSIS
        Lists saved destination profiles, or returns one by name.

    .PARAMETER Name
        Optional profile name (wildcards allowed).

    .EXAMPLE
        Get-AppServicePromotionDestination

    .EXAMPLE
        Get-AppServicePromotionDestination -Name prod

    .OUTPUTS
        PSCustomObject with Name, Subscription, Tenant, ResourceGroupName, AppName, Slot.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Position = 0)][SupportsWildcards()][string] $Name = '*')

    $config = Read-PromotionConfig
    $found = $false
    foreach ($key in @($config.Destinations.Keys)) {
        if ($key -notlike $Name) { continue }
        $found = $true
        $d = $config.Destinations[$key]
        [pscustomobject][ordered]@{
            Name              = $key
            Subscription      = $d.Subscription
            Tenant            = $d.Tenant
            ResourceGroupName = $d.ResourceGroupName
            AppName           = $d.AppName
            Slot              = $d.Slot
        }
    }
    if (-not $found -and -not [WildcardPattern]::ContainsWildcardCharacters($Name)) {
        Write-Error "Destination profile '$Name' was not found." -Category ObjectNotFound
    }
}
