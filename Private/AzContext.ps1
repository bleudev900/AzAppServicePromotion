function Enter-PromotionSubscription {
    <#
    .SYNOPSIS
        Switches the Az context to the given subscription and returns the previous context.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Subscription,
        [string] $Tenant
    )

    $prior = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $prior) {
        throw 'No Azure context found. Run Connect-AzAccount first.'
    }
    $params = @{ Subscription = $Subscription; ErrorAction = 'Stop' }
    if ($Tenant) { $params['Tenant'] = $Tenant }
    Write-Verbose "Switching Az context to subscription '$Subscription'."
    $null = Set-AzContext @params
    return $prior
}

function Restore-PromotionContext {
    <#
    .SYNOPSIS
        Restores a previously captured Az context (best effort).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()] $Context)

    if (-not $Context) { return }
    try {
        Write-Verbose 'Restoring previous Az context.'
        $null = Set-AzContext -Context $Context -ErrorAction Stop
    }
    catch {
        Write-Warning "Could not restore the previous Az context: $($_.Exception.Message)"
    }
}
