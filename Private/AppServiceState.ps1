function Get-PromotionAppServiceState {
    <#
    .SYNOPSIS
        Reads app settings, connection strings and slot-sticky names of an App Service (or slot).
        Assumes the Az context is already set to the right subscription.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Target)

    if ($Target.Slot) {
        $site = Get-AzWebAppSlot -ResourceGroupName $Target.ResourceGroupName -Name $Target.AppName -Slot $Target.Slot -ErrorAction Stop
    }
    else {
        $site = Get-AzWebApp -ResourceGroupName $Target.ResourceGroupName -Name $Target.AppName -ErrorAction Stop
    }
    if (-not $site) {
        throw "App Service '$(Format-PromotionTarget -Target $Target)' was not found."
    }

    $stickyApp = @()
    $stickyConn = @()
    $slotConfig = Get-AzWebAppSlotConfigName -ResourceGroupName $Target.ResourceGroupName -Name $Target.AppName -ErrorAction Stop
    if ($slotConfig) {
        if ($slotConfig.PSObject.Properties['AppSettingNames'] -and $slotConfig.AppSettingNames) {
            $stickyApp = @($slotConfig.AppSettingNames)
        }
        if ($slotConfig.PSObject.Properties['ConnectionStringNames'] -and $slotConfig.ConnectionStringNames) {
            $stickyConn = @($slotConfig.ConnectionStringNames)
        }
    }

    $siteConfig = $null
    if ($site.PSObject.Properties['SiteConfig']) { $siteConfig = $site.SiteConfig }

    $appSettings = New-Object System.Collections.Generic.List[object]
    $connectionStrings = New-Object System.Collections.Generic.List[object]
    if ($siteConfig) {
        if ($siteConfig.PSObject.Properties['AppSettings']) {
            foreach ($s in @($siteConfig.AppSettings)) {
                if ($null -eq $s) { continue }
                $appSettings.Add([pscustomobject][ordered]@{
                        name        = [string]$s.Name
                        value       = [string]$s.Value
                        slotSetting = [bool]($stickyApp -contains $s.Name)
                    })
            }
        }
        if ($siteConfig.PSObject.Properties['ConnectionStrings']) {
            foreach ($c in @($siteConfig.ConnectionStrings)) {
                if ($null -eq $c) { continue }
                $type = if ($null -ne $c.Type -and "$($c.Type)" -ne '') { "$($c.Type)" } else { 'Custom' }
                $connectionStrings.Add([pscustomobject][ordered]@{
                        name        = [string]$c.Name
                        value       = [string]$c.ConnectionString
                        type        = $type
                        slotSetting = [bool]($stickyConn -contains $c.Name)
                    })
            }
        }
    }

    [pscustomobject]@{
        AppSettings                 = @($appSettings | Sort-Object -Property name)
        ConnectionStrings           = @($connectionStrings | Sort-Object -Property name)
        StickyAppSettingNames       = $stickyApp
        StickyConnectionStringNames = $stickyConn
    }
}
