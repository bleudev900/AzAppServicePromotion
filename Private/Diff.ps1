function Get-PromotionDiff {
    <#
    .SYNOPSIS
        Computes the difference between desired settings (from a file) and current destination settings.
    .DESCRIPTION
        Returns one item per setting with Action:
          Add       - in file, not in destination
          Change    - in both, value / slotSetting / type differ
          Remove    - only in destination and Mode is Replace (will be deleted)
          Keep      - only in destination and Mode is Merge (left untouched)
          Unchanged - identical
        Raw values are returned in CurrentValue/NewValue; callers mask for display.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] $Desired,
        [Parameter(Mandatory)] $Current,
        [ValidateSet('Merge', 'Replace')][string] $Mode = 'Merge'
    )

    $result = New-Object System.Collections.Generic.List[object]
    $kinds = @(
        @{ Kind = 'AppSetting'; Desired = @($Desired.AppSettings); Current = @($Current.AppSettings); HasType = $false },
        @{ Kind = 'ConnectionString'; Desired = @($Desired.ConnectionStrings); Current = @($Current.ConnectionStrings); HasType = $true }
    )

    foreach ($k in $kinds) {
        $currentByName = @{}
        foreach ($c in $k.Current) { if ($null -ne $c) { $currentByName[$c.name] = $c } }
        $desiredNames = @{}

        foreach ($d in $k.Desired) {
            if ($null -eq $d) { continue }
            $desiredNames[$d.name] = $true
            $cur = $currentByName[$d.name]
            $newType = if ($k.HasType) { $d.type } else { $null }
            if ($null -eq $cur) {
                $result.Add((New-PromotionDiffItem -Kind $k.Kind -Name $d.name -Action 'Add' -Changes @('Value') `
                            -NewValue $d.value -NewSlotSetting $d.slotSetting -NewType $newType))
                continue
            }
            $changes = @()
            if ([string]$cur.value -cne [string]$d.value) { $changes += 'Value' }
            if ([bool]$cur.slotSetting -ne [bool]$d.slotSetting) { $changes += 'SlotSetting' }
            $curType = if ($k.HasType) { $cur.type } else { $null }
            if ($k.HasType -and $curType -ine $newType) { $changes += 'Type' }
            $action = if ($changes.Count -gt 0) { 'Change' } else { 'Unchanged' }
            $result.Add((New-PromotionDiffItem -Kind $k.Kind -Name $d.name -Action $action -Changes $changes `
                        -CurrentValue $cur.value -NewValue $d.value -CurrentSlotSetting $cur.slotSetting `
                        -NewSlotSetting $d.slotSetting -CurrentType $curType -NewType $newType))
        }

        foreach ($c in $k.Current) {
            if ($null -eq $c -or $desiredNames.ContainsKey($c.name)) { continue }
            $curType = if ($k.HasType) { $c.type } else { $null }
            if ($Mode -eq 'Replace') {
                $result.Add((New-PromotionDiffItem -Kind $k.Kind -Name $c.name -Action 'Remove' -Changes @('Value') `
                            -CurrentValue $c.value -CurrentSlotSetting $c.slotSetting -CurrentType $curType))
            }
            else {
                $result.Add((New-PromotionDiffItem -Kind $k.Kind -Name $c.name -Action 'Keep' -Changes @() `
                            -CurrentValue $c.value -NewValue $c.value -CurrentSlotSetting $c.slotSetting `
                            -NewSlotSetting $c.slotSetting -CurrentType $curType -NewType $curType))
            }
        }
    }

    $order = @{ Add = 0; Change = 1; Remove = 2; Keep = 3; Unchanged = 4 }
    return @($result | Sort-Object -Property @{ Expression = { $_.Kind } }, @{ Expression = { $order[$_.Action] } }, @{ Expression = { $_.Name } })
}

function New-PromotionDiffItem {
    <#
    .SYNOPSIS
        Creates a diff item object.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an in-memory object only.')]
    param(
        [string] $Kind, [string] $Name, [string] $Action, [string[]] $Changes,
        [AllowNull()] $CurrentValue, [AllowNull()] $NewValue,
        [AllowNull()] $CurrentSlotSetting, [AllowNull()] $NewSlotSetting,
        [AllowNull()] $CurrentType, [AllowNull()] $NewType
    )
    $o = [pscustomobject][ordered]@{
        Kind               = $Kind
        Action             = $Action
        Name               = $Name
        Changes            = (@($Changes) -join ',')
        CurrentValue       = $CurrentValue
        NewValue           = $NewValue
        CurrentSlotSetting = $CurrentSlotSetting
        NewSlotSetting     = $NewSlotSetting
        CurrentType        = $CurrentType
        NewType            = $NewType
    }
    $o.PSObject.TypeNames.Insert(0, 'AzAppServicePromotion.DiffItem')
    return $o
}

function Get-PromotionDisplayDiff {
    <#
    .SYNOPSIS
        Returns diff items with values masked unless ShowValues is set.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()] [object[]] $Diff,
        [switch] $ShowValues
    )
    foreach ($d in $Diff) {
        if ($null -eq $d) { continue }
        if ($ShowValues) { $d; continue }
        $copy = $d.PSObject.Copy()
        $copy.CurrentValue = Hide-PromotionValue -Value $d.CurrentValue
        $copy.NewValue = Hide-PromotionValue -Value $d.NewValue
        $copy
    }
}

function New-StickyNameList {
    <#
    .SYNOPSIS
        Computes the desired slot-sticky name list: existing names, plus/minus names from the file per their slotSetting flag.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Pure computation.')]
    [OutputType([string[]], [object[]])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()] [object[]] $Current,
        [Parameter()][AllowNull()][AllowEmptyCollection()] [object[]] $Desired
    )
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($n in @($Current)) { if ($n -and -not ($list -contains $n)) { $list.Add([string]$n) } }
    foreach ($d in @($Desired)) {
        if ($null -eq $d) { continue }
        $existing = @($list | Where-Object { $_ -ieq $d.name })
        if ($d.slotSetting) {
            if ($existing.Count -eq 0) { $list.Add([string]$d.name) }
        }
        else {
            foreach ($e in $existing) { [void]$list.Remove($e) }
        }
    }
    return , ([string[]]$list.ToArray())
}

function Test-SameNameSet {
    <#
    .SYNOPSIS
        Case-insensitive set equality of two name lists.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()] [object[]] $Left,
        [Parameter()][AllowNull()][AllowEmptyCollection()] [object[]] $Right
    )
    $l = @(@($Left) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    $r = @(@($Right) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
    if ($l.Count -ne $r.Count) { return $false }
    for ($i = 0; $i -lt $l.Count; $i++) { if ($l[$i] -ne $r[$i]) { return $false } }
    return $true
}
