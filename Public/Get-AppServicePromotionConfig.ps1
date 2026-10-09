function Get-AppServicePromotionConfig {
    <#
    .SYNOPSIS
        Shows the saved promotion configuration (source App Service, export directory, destination profiles).

    .DESCRIPTION
        Reads the per-user configuration file and returns an object with the config file path,
        the source App Service, the default export directory and the names of saved destination profiles.

    .EXAMPLE
        Get-AppServicePromotionConfig

    .EXAMPLE
        (Get-AppServicePromotionConfig).Source

    .OUTPUTS
        PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()

    $config = Read-PromotionConfig
    [pscustomobject]@{
        ConfigPath      = Get-PromotionConfigPath
        Source          = $config.Source
        ExportDirectory = $config.ExportDirectory
        Destinations    = @($config.Destinations.Keys)
    }
}
