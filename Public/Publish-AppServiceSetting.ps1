function Publish-AppServiceSetting {
    <#
    .SYNOPSIS
        Applies an (edited) settings file to the destination App Service in the destination subscription.

    .DESCRIPTION
        1. Reads and validates the settings file produced by Export-AppServiceSetting.
        2. Switches the Az context to the destination subscription.
        3. Reads the destination's current app settings, connection strings and slot-sticky names.
        4. Shows the diff (Add / Change / Remove / Keep) - values masked unless -ShowValues.
        5. After confirmation (supports -WhatIf / -Confirm; -Force skips the prompt) applies the result:
             * Set-AzWebApp / Set-AzWebAppSlot -AppSettings / -ConnectionStrings. These cmdlets
               REPLACE the whole collection, so the final collection is computed client-side:
               Merge (default) = destination settings overlaid with the file; Replace = the file only.
               A collection is only sent when something in it changed.
             * Set-AzWebAppSlotConfigName for slot-sticky ("deployment slot setting") names.
               The sticky-name list is shared by the production app and all its slots, so names in
               the file are made sticky / non-sticky according to their slotSetting flag and every
               other existing sticky name is preserved.
        6. Restores the previous Az context (also on failure).

    .PARAMETER Path
        Path of the settings file.

    .PARAMETER Destination
        Name of a saved destination profile. Explicit parameters override the profile's values.

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
        Merge (default) keeps settings that exist only on the destination; Replace removes them.

    .PARAMETER ShowValues
        Show values in clear text in the diff.

    .PARAMETER Force
        Apply without prompting for confirmation (-WhatIf is still honoured).

    .EXAMPLE
        Publish-AppServiceSetting -Path ./promote-prod.json -Destination prod -WhatIf

        Shows the diff and what would be applied; changes nothing.

    .EXAMPLE
        Publish-AppServiceSetting -Path ./promote-prod.json -Destination prod

        Shows the diff, asks for confirmation and applies (merge mode).

    .EXAMPLE
        Publish-AppServiceSetting ./promote-prod.json -Subscription 'Contoso-Prod' -ResourceGroupName rg-web-prod -AppName contoso-web-prod -Slot staging -Mode Replace -Force

    .OUTPUTS
        PSCustomObject summary (Target, Mode, Applied, counts and the masked Diff).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive diff display; Write-Host writes to the information stream in PS 5+.')]
    param(
        [Parameter(Mandatory, Position = 0)][string] $Path,
        [string] $Destination,
        [string] $Subscription,
        [string] $Tenant,
        [string] $ResourceGroupName,
        [string] $AppName,
        [AllowEmptyString()][string] $Slot,
        [ValidateSet('Merge', 'Replace')][string] $Mode = 'Merge',
        [switch] $ShowValues,
        [switch] $Force
    )

    if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }

    $desired = Read-PromotionSettingsFile -Path $Path
    $target = Resolve-PromotionDestinationFromParameter -BoundParameters $PSBoundParameters
    $targetText = Format-PromotionTarget -Target $target

    if ($desired.Metadata -and $desired.Metadata.PSObject.Properties['source'] -and $desired.Metadata.source) {
        $src = $desired.Metadata.source
        $srcSlot = if ($src.PSObject.Properties['slot']) { [string]$src.slot } else { '' }
        $sameSub = ($src.subscriptionId -and $src.subscriptionId -ieq $target.Subscription) -or
                   ($src.PSObject.Properties['subscriptionName'] -and $src.subscriptionName -and $src.subscriptionName -ieq $target.Subscription)
        if ($sameSub -and $src.resourceGroupName -ieq $target.ResourceGroupName -and
            $src.appName -ieq $target.AppName -and $srcSlot -ieq [string]$target.Slot) {
            Write-Warning "The destination ($targetText) is the same App Service the file was exported from."
        }
    }

    $prior = Enter-PromotionSubscription -Subscription $target.Subscription -Tenant $target.Tenant
    try {
        $current = Get-PromotionAppServiceState -Target $target
        $diff = @(Get-PromotionDiff -Desired $desired -Current $current -Mode $Mode)
        $pending = @($diff | Where-Object { $_.Action -in 'Add', 'Change', 'Remove' })
        $display = @(Get-PromotionDisplayDiff -Diff @($diff | Where-Object { $_.Action -ne 'Unchanged' }) -ShowValues:$ShowValues)

        $summary = [pscustomobject][ordered]@{
            Target    = $targetText
            Mode      = $Mode
            Applied   = $false
            Added     = @($diff | Where-Object { $_.Action -eq 'Add' }).Count
            Changed   = @($diff | Where-Object { $_.Action -eq 'Change' }).Count
            Removed   = @($diff | Where-Object { $_.Action -eq 'Remove' }).Count
            Kept      = @($diff | Where-Object { $_.Action -eq 'Keep' }).Count
            Unchanged = @($diff | Where-Object { $_.Action -eq 'Unchanged' }).Count
            Diff      = $display
        }

        Write-Host "Destination: $targetText (mode: $Mode)"
        if ($display.Count -gt 0) {
            Write-Host ($display | Format-Table -Property Kind, Action, Name, Changes, CurrentValue, NewValue, NewSlotSetting -AutoSize | Out-String -Width 200).TrimEnd()
        }
        Write-Host ("Add: {0}  Change: {1}  Remove: {2}  Keep: {3}  Unchanged: {4}" -f $summary.Added, $summary.Changed, $summary.Removed, $summary.Kept, $summary.Unchanged)

        if ($pending.Count -eq 0) {
            Write-Host 'No changes to apply.'
            return $summary
        }

        # --- Compute the final collections client-side (Set-AzWebApp replaces whole collections) ---
        $appChanged = @($pending | Where-Object { $_.Kind -eq 'AppSetting' -and ($_.Action -ne 'Change' -or $_.Changes -match 'Value') }).Count -gt 0
        $connChanged = @($pending | Where-Object { $_.Kind -eq 'ConnectionString' -and ($_.Action -ne 'Change' -or $_.Changes -match 'Value|Type') }).Count -gt 0

        $finalAppSettings = @{}
        if ($Mode -eq 'Merge') {
            foreach ($s in $current.AppSettings) { $finalAppSettings[$s.name] = [string]$s.value }
        }
        foreach ($s in $desired.AppSettings) { $finalAppSettings[$s.name] = [string]$s.value }

        $finalConnectionStrings = @{}
        if ($Mode -eq 'Merge') {
            foreach ($c in $current.ConnectionStrings) { $finalConnectionStrings[$c.name] = @{ Type = [string]$c.type; Value = [string]$c.value } }
        }
        foreach ($c in $desired.ConnectionStrings) { $finalConnectionStrings[$c.name] = @{ Type = [string]$c.type; Value = [string]$c.value } }

        # --- Sticky (slot setting) names: shared across all slots of the app, so preserve others ---
        $stickyApp = New-StickyNameList -Current $current.StickyAppSettingNames -Desired $desired.AppSettings
        $stickyConn = New-StickyNameList -Current $current.StickyConnectionStringNames -Desired $desired.ConnectionStrings
        $stickyAppChanged = -not (Test-SameNameSet -Left $stickyApp -Right $current.StickyAppSettingNames)
        $stickyConnChanged = -not (Test-SameNameSet -Left $stickyConn -Right $current.StickyConnectionStringNames)

        $action = "Apply $($pending.Count) setting change(s) (Add: $($summary.Added), Change: $($summary.Changed), Remove: $($summary.Removed)) in $Mode mode"
        if (-not $PSCmdlet.ShouldProcess($targetText, $action)) {
            return $summary
        }

        if ($appChanged -or $connChanged) {
            $setParams = @{
                ResourceGroupName = $target.ResourceGroupName
                Name              = $target.AppName
                ErrorAction       = 'Stop'
            }
            if ($appChanged) { $setParams['AppSettings'] = $finalAppSettings }
            if ($connChanged) { $setParams['ConnectionStrings'] = $finalConnectionStrings }
            if ($target.Slot) {
                $setParams['Slot'] = $target.Slot
                Write-Verbose "Set-AzWebAppSlot on $targetText"
                $null = Set-AzWebAppSlot @setParams
            }
            else {
                Write-Verbose "Set-AzWebApp on $targetText"
                $null = Set-AzWebApp @setParams
            }
        }

        if ($stickyAppChanged -or $stickyConnChanged) {
            $slotParams = @{
                ResourceGroupName = $target.ResourceGroupName
                Name              = $target.AppName
                ErrorAction       = 'Stop'
            }
            if ($stickyAppChanged) {
                if ($stickyApp.Count -gt 0) { $slotParams['AppSettingNames'] = [string[]]$stickyApp } else { $slotParams['RemoveAllAppSettingNames'] = $true }
            }
            if ($stickyConnChanged) {
                if ($stickyConn.Count -gt 0) { $slotParams['ConnectionStringNames'] = [string[]]$stickyConn } else { $slotParams['RemoveAllConnectionStringNames'] = $true }
            }
            Write-Verbose "Set-AzWebAppSlotConfigName on $($target.ResourceGroupName)/$($target.AppName)"
            $null = Set-AzWebAppSlotConfigName @slotParams
        }

        $summary.Applied = $true
        Write-Host "Applied settings to $targetText."
        return $summary
    }
    finally {
        Restore-PromotionContext -Context $prior
    }
}
