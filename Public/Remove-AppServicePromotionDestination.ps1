function Remove-AppServicePromotionDestination {
    <#
    .SYNOPSIS
        Removes a saved destination profile.

    .PARAMETER Name
        Profile name to remove.

    .EXAMPLE
        Remove-AppServicePromotionDestination -Name test
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory, Position = 0)][ValidateNotNullOrEmpty()][string] $Name)

    $config = Read-PromotionConfig
    $key = @($config.Destinations.Keys) | Where-Object { $_ -ieq $Name } | Select-Object -First 1
    if (-not $key) {
        Write-Error "Destination profile '$Name' was not found." -Category ObjectNotFound
        return
    }
    if ($PSCmdlet.ShouldProcess($key, 'Remove destination profile')) {
        $config.Destinations.Remove($key)
        Write-PromotionConfig -Config $config
    }
}
