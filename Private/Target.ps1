function Resolve-PromotionTarget {
    <#
    .SYNOPSIS
        Builds a target (subscription/resource group/app/slot) from a base object
        (saved source or destination profile) overridden by explicit values.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()] $Base,
        [string] $Subscription,
        [string] $Tenant,
        [string] $ResourceGroupName,
        [string] $AppName,
        [string] $Slot,
        [switch] $SlotSpecified,
        [Parameter(Mandatory)][string] $Role
    )

    $t = [pscustomobject]@{
        Subscription      = $null
        Tenant            = $null
        ResourceGroupName = $null
        AppName           = $null
        Slot              = $null
    }
    if ($Base) {
        foreach ($n in 'Subscription', 'Tenant', 'ResourceGroupName', 'AppName', 'Slot') { $t.$n = $Base.$n }
    }
    if ($Subscription)      { $t.Subscription = $Subscription }
    if ($Tenant)            { $t.Tenant = $Tenant }
    if ($ResourceGroupName) { $t.ResourceGroupName = $ResourceGroupName }
    if ($AppName)           { $t.AppName = $AppName }
    if ($SlotSpecified)     { $t.Slot = $Slot }
    if ($t.Slot -and $t.Slot -ieq 'production') { $t.Slot = $null }

    $missing = @()
    foreach ($n in 'Subscription', 'ResourceGroupName', 'AppName') {
        if ([string]::IsNullOrWhiteSpace($t.$n)) { $missing += $n }
    }
    if ($missing.Count -gt 0) {
        throw "The $Role App Service is not fully specified (missing: $($missing -join ', ')). Provide the parameters explicitly or save them in the configuration."
    }
    return $t
}

function Format-PromotionTarget {
    <#
    .SYNOPSIS
        Returns a human-readable description of a target.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Target)
    $slot = if ($Target.Slot) { "/slots/$($Target.Slot)" } else { '' }
    return "$($Target.Subscription)/$($Target.ResourceGroupName)/$($Target.AppName)$slot"
}

function Resolve-PromotionDestinationFromParameter {
    <#
    .SYNOPSIS
        Resolves the destination target from -Destination profile name and/or explicit parameters.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $BoundParameters)

    $base = $null
    if ($BoundParameters.ContainsKey('Destination') -and $BoundParameters['Destination']) {
        $config = Read-PromotionConfig
        $name = $BoundParameters['Destination']
        $key = @($config.Destinations.Keys) | Where-Object { $_ -ieq $name } | Select-Object -First 1
        if (-not $key) {
            throw "Destination profile '$name' was not found. Use Set-AppServicePromotionDestination to create it."
        }
        $base = $config.Destinations[$key]
    }
    $p = @{ Base = $base; Role = 'destination' }
    foreach ($n in 'Subscription', 'Tenant', 'ResourceGroupName', 'AppName') {
        if ($BoundParameters.ContainsKey($n)) { $p[$n] = $BoundParameters[$n] }
    }
    if ($BoundParameters.ContainsKey('Slot')) { $p['Slot'] = $BoundParameters['Slot']; $p['SlotSpecified'] = $true }
    Resolve-PromotionTarget @p
}
