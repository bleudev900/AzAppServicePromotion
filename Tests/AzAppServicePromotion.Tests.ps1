#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ModuleRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ModuleName = 'AzAppServicePromotion'

    # If Az.Accounts / Az.Websites are not installed, create minimal stub modules so the
    # manifest's RequiredModules resolve and the commands exist for mocking.
    $needed = @('Az.Accounts', 'Az.Websites') | Where-Object { -not (Get-Module -ListAvailable -Name $_) }
    if ($needed) {
        $stubRoot = Join-Path ([IO.Path]::GetTempPath()) ("azasp-stubs-" + [guid]::NewGuid())
        $stubs = @{
            'Az.Accounts' = @'
function Get-AzContext { [CmdletBinding()] param() }
function Set-AzContext { [CmdletBinding()] param([object] $Context, [string] $Subscription, [string] $Tenant) }
'@
            'Az.Websites' = @'
function Get-AzWebApp { [CmdletBinding()] param([string] $ResourceGroupName, [string] $Name) }
function Get-AzWebAppSlot { [CmdletBinding()] param([string] $ResourceGroupName, [string] $Name, [string] $Slot) }
function Set-AzWebApp { [CmdletBinding()] param([string] $ResourceGroupName, [string] $Name, [hashtable] $AppSettings, [hashtable] $ConnectionStrings) }
function Set-AzWebAppSlot { [CmdletBinding()] param([string] $ResourceGroupName, [string] $Name, [string] $Slot, [hashtable] $AppSettings, [hashtable] $ConnectionStrings) }
function Get-AzWebAppSlotConfigName { [CmdletBinding()] param([string] $ResourceGroupName, [string] $Name) }
function Set-AzWebAppSlotConfigName { [CmdletBinding()] param([string] $ResourceGroupName, [string] $Name, [string[]] $AppSettingNames, [string[]] $ConnectionStringNames, [switch] $RemoveAllAppSettingNames, [switch] $RemoveAllConnectionStringNames) }
'@
        }
        foreach ($n in $needed) {
            $dir = Join-Path (Join-Path $stubRoot $n) '2.0.0'
            $null = New-Item -ItemType Directory -Path $dir -Force
            Set-Content -Path (Join-Path $dir "$n.psm1") -Value $stubs[$n]
            New-ModuleManifest -Path (Join-Path $dir "$n.psd1") -RootModule "$n.psm1" -ModuleVersion '2.0.0' -FunctionsToExport '*'
        }
        $env:PSModulePath = $stubRoot + [IO.Path]::PathSeparator + $env:PSModulePath
    }

    Get-Module $script:ModuleName | Remove-Module -Force
    Import-Module (Join-Path $script:ModuleRoot "$($script:ModuleName).psd1") -Force

    function script:New-FakeSite {
        param([hashtable] $AppSettings = @{}, [object[]] $ConnectionStrings = @())
        [pscustomobject]@{
            SiteConfig = [pscustomobject]@{
                AppSettings       = @($AppSettings.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } })
                ConnectionStrings = @($ConnectionStrings | ForEach-Object { [pscustomobject]@{ Name = $_.Name; ConnectionString = $_.Value; Type = $_.Type } })
            }
        }
    }

    function script:New-SettingsFile {
        param([string] $Path, [object[]] $AppSettings = @(), [object[]] $ConnectionStrings = @(), $Source = $null)
        $doc = [ordered]@{
            schemaVersion     = 1
            metadata          = [ordered]@{ source = $Source }
            appSettings       = @($AppSettings)
            connectionStrings = @($ConnectionStrings)
        }
        Set-Content -Path $Path -Value ($doc | ConvertTo-Json -Depth 10)
        $Path
    }

    function script:Register-AzMock {
        param(
            [hashtable] $AppSettings = @{},
            [object[]] $ConnectionStrings = @(),
            [string[]] $StickyApp = @(),
            [string[]] $StickyConn = @()
        )
        $m = $script:ModuleName
        $site = New-FakeSite -AppSettings $AppSettings -ConnectionStrings $ConnectionStrings
        $slotCfg = [pscustomobject]@{ AppSettingNames = $StickyApp; ConnectionStringNames = $StickyConn }

        Mock -ModuleName $m Get-AzContext {
            [pscustomobject]@{ Name = 'prior'; Account = 'user@contoso.com'; Subscription = [pscustomobject]@{ Id = '00000000-src'; Name = 'Contoso-Dev' } }
        }
        Mock -ModuleName $m Set-AzContext { } -RemoveParameterType Context
        Mock -ModuleName $m Get-AzWebApp { $site }.GetNewClosure()
        Mock -ModuleName $m Get-AzWebAppSlot { $site }.GetNewClosure()
        Mock -ModuleName $m Get-AzWebAppSlotConfigName { $slotCfg }.GetNewClosure()
        Mock -ModuleName $m Set-AzWebApp { }
        Mock -ModuleName $m Set-AzWebAppSlot { }
        Mock -ModuleName $m Set-AzWebAppSlotConfigName { }
        Mock -ModuleName $m Write-Host { }
    }
}

AfterAll {
    Get-Module AzAppServicePromotion | Remove-Module -Force
}

Describe 'Module' {
    It 'passes Test-ModuleManifest' {
        { Test-ModuleManifest -Path (Join-Path $script:ModuleRoot 'AzAppServicePromotion.psd1') -ErrorAction Stop } | Should -Not -Throw
    }

    It 'exports exactly the public functions' {
        $expected = (Get-ChildItem (Join-Path $script:ModuleRoot 'Public') -Filter *.ps1).BaseName | Sort-Object
        (Get-Command -Module AzAppServicePromotion).Name | Sort-Object | Should -Be $expected
    }

    It '<_> has comment-based help with synopsis, description and an example' -ForEach @(
        'Set-AppServicePromotionConfig', 'Get-AppServicePromotionConfig', 'Set-AppServicePromotionDestination',
        'Get-AppServicePromotionDestination', 'Remove-AppServicePromotionDestination',
        'Export-AppServiceSetting', 'Compare-AppServiceSetting', 'Publish-AppServiceSetting'
    ) {
        $help = Get-Help $_ -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match '^\s*\S+ \['
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }
}

Describe 'Configuration' {
    BeforeEach {
        $env:AZAPPSERVICEPROMOTION_CONFIG = Join-Path $TestDrive ("config-{0}.json" -f [guid]::NewGuid())
    }
    AfterAll {
        Remove-Item Env:\AZAPPSERVICEPROMOTION_CONFIG -ErrorAction SilentlyContinue
    }

    It 'defaults to a per-user path under the home directory' {
        $saved = $env:AZAPPSERVICEPROMOTION_CONFIG
        try {
            Remove-Item Env:\AZAPPSERVICEPROMOTION_CONFIG
            $p = InModuleScope AzAppServicePromotion { Get-PromotionConfigPath }
            $p | Should -BeLike "*.azappservicepromotion*config.json"
            $p | Should -BeLike ([Environment]::GetFolderPath('UserProfile') + '*')
        }
        finally { $env:AZAPPSERVICEPROMOTION_CONFIG = $saved }
    }

    It 'returns empty config when no file exists' {
        $c = Get-AppServicePromotionConfig
        $c.Source | Should -BeNullOrEmpty
        @($c.Destinations).Count | Should -Be 0
    }

    It 'saves and reads the source App Service' {
        Set-AppServicePromotionConfig -Subscription 'sub-a' -ResourceGroupName 'rg-a' -AppName 'app-a' -Slot 'staging' -ExportDirectory $TestDrive
        $c = Get-AppServicePromotionConfig
        $c.Source.Subscription | Should -Be 'sub-a'
        $c.Source.ResourceGroupName | Should -Be 'rg-a'
        $c.Source.AppName | Should -Be 'app-a'
        $c.Source.Slot | Should -Be 'staging'
        $c.ExportDirectory | Should -Be $TestDrive
        Test-Path $env:AZAPPSERVICEPROMOTION_CONFIG | Should -BeTrue
    }

    It 'updates only the parameters passed and clears slot with production' {
        Set-AppServicePromotionConfig -Subscription 'sub-a' -ResourceGroupName 'rg-a' -AppName 'app-a' -Slot 'staging'
        Set-AppServicePromotionConfig -AppName 'app-b' -Slot 'production'
        $c = Get-AppServicePromotionConfig
        $c.Source.Subscription | Should -Be 'sub-a'
        $c.Source.AppName | Should -Be 'app-b'
        $c.Source.Slot | Should -BeNullOrEmpty
    }

    It 'does not write with -WhatIf' {
        Set-AppServicePromotionConfig -Subscription 'x' -WhatIf
        Test-Path $env:AZAPPSERVICEPROMOTION_CONFIG | Should -BeFalse
    }

    It 'manages destination profiles' {
        Set-AppServicePromotionDestination -Name prod -Subscription 'sub-p' -ResourceGroupName 'rg-p' -AppName 'app-p'
        Set-AppServicePromotionDestination -Name test -Subscription 'sub-t' -ResourceGroupName 'rg-t' -AppName 'app-t' -Slot 'blue'
        @(Get-AppServicePromotionDestination).Count | Should -Be 2
        (Get-AppServicePromotionDestination -Name test).Slot | Should -Be 'blue'

        Set-AppServicePromotionDestination -Name PROD -AppName 'app-p2'
        $p = Get-AppServicePromotionDestination -Name prod
        $p.AppName | Should -Be 'app-p2'
        $p.Subscription | Should -Be 'sub-p'

        Remove-AppServicePromotionDestination -Name test -Confirm:$false
        @(Get-AppServicePromotionDestination).Count | Should -Be 1
        (Get-AppServicePromotionConfig).Source | Should -BeNullOrEmpty
    }

    It 'rejects incomplete destination profiles' {
        { Set-AppServicePromotionDestination -Name bad -Subscription 'x' } | Should -Throw '*missing*'
    }

    It 'errors for an unknown profile' {
        { Get-AppServicePromotionDestination -Name nope -ErrorAction Stop } | Should -Throw '*not found*'
    }
}

Describe 'Export-AppServiceSetting' {
    BeforeEach {
        $env:AZAPPSERVICEPROMOTION_CONFIG = Join-Path $TestDrive ("config-{0}.json" -f [guid]::NewGuid())
        Set-AppServicePromotionConfig -Subscription 'src-sub' -ResourceGroupName 'rg-src' -AppName 'app-src'
        Register-AzMock -AppSettings @{ API_URL = 'https://dev.api'; SECRET = 'p@ss'; KV = '@Microsoft.KeyVault(SecretUri=https://kv.vault.azure.net/secrets/x)'; WEBSITE_NODE_DEFAULT_VERSION = '~18' } `
            -ConnectionStrings @(@{ Name = 'Db'; Value = 'Server=dev;'; Type = 'SQLAzure' }) -StickyApp @('API_URL') -StickyConn @('Db')
        Mock -ModuleName AzAppServicePromotion Write-Warning { }
    }

    It 'writes an editable JSON file with metadata, settings, slot flags and connection string types' {
        $out = Join-Path $TestDrive 'export1.json'
        $file = Export-AppServiceSetting -Path $out
        $file.FullName | Should -Be $out
        $doc = Get-Content $out -Raw | ConvertFrom-Json

        $doc.schemaVersion | Should -Be 1
        $doc.metadata.source.appName | Should -Be 'app-src'
        $doc.metadata.source.resourceGroupName | Should -Be 'rg-src'
        $doc.metadata.exportedAtUtc | Should -Not -BeNullOrEmpty
        $doc.metadata.exportedBy | Should -Be 'user@contoso.com'
        @($doc.appSettings).Count | Should -Be 4
        ($doc.appSettings | Where-Object name -eq 'API_URL').slotSetting | Should -BeTrue
        ($doc.appSettings | Where-Object name -eq 'SECRET').slotSetting | Should -BeFalse
        ($doc.appSettings | Where-Object name -eq 'SECRET').value | Should -Be 'p@ss'
        ($doc.appSettings | Where-Object name -eq 'KV').value | Should -BeLike '@Microsoft.KeyVault(*'
        $doc.connectionStrings[0].type | Should -Be 'SQLAzure'
        $doc.connectionStrings[0].slotSetting | Should -BeTrue
    }

    It 'switches to the source subscription and restores the previous context' {
        Export-AppServiceSetting -Path (Join-Path $TestDrive 'export2.json') | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Subscription -eq 'src-sub' }
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Context.Name -eq 'prior' }
        Should -Invoke -ModuleName AzAppServicePromotion Get-AzWebApp -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-src' -and $Name -eq 'app-src' }
        Should -Invoke -ModuleName AzAppServicePromotion Get-AzWebAppSlot -Times 0 -Exactly
    }

    It 'warns that the file contains secrets' {
        Export-AppServiceSetting -Path (Join-Path $TestDrive 'export3.json') | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Write-Warning -ParameterFilter { $Message -like '*secrets*gitignore*' }
    }

    It 'uses Get-AzWebAppSlot for a slot and honours explicit overrides' {
        Export-AppServiceSetting -Path (Join-Path $TestDrive 'export4.json') -Slot staging -AppName 'other-app' | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Get-AzWebAppSlot -Times 1 -Exactly -ParameterFilter { $Slot -eq 'staging' -and $Name -eq 'other-app' }
        $doc = Get-Content (Join-Path $TestDrive 'export4.json') -Raw | ConvertFrom-Json
        $doc.metadata.source.slot | Should -Be 'staging'
    }

    It 'excludes settings matching -ExcludeSetting' {
        $out = Join-Path $TestDrive 'export5.json'
        Export-AppServiceSetting -Path $out -ExcludeSetting 'WEBSITE_*', 'Db' | Out-Null
        $doc = Get-Content $out -Raw | ConvertFrom-Json
        $doc.appSettings.name | Should -Not -Contain 'WEBSITE_NODE_DEFAULT_VERSION'
        @($doc.connectionStrings).Count | Should -Be 0
    }

    It 'refuses to overwrite without -Force' {
        $out = Join-Path $TestDrive 'export6.json'
        Set-Content $out 'x'
        { Export-AppServiceSetting -Path $out } | Should -Throw '*already exists*'
        { Export-AppServiceSetting -Path $out -Force } | Should -Not -Throw
    }

    It 'restores the context when reading the App Service fails' {
        Mock -ModuleName AzAppServicePromotion Get-AzWebApp { throw 'boom' }
        { Export-AppServiceSetting -Path (Join-Path $TestDrive 'export7.json') } | Should -Throw '*boom*'
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Context.Name -eq 'prior' }
    }

    It 'requires a signed-in Az context' {
        Mock -ModuleName AzAppServicePromotion Get-AzContext { $null }
        { Export-AppServiceSetting -Path (Join-Path $TestDrive 'export8.json') } | Should -Throw '*Connect-AzAccount*'
    }

    It 'fails clearly when no source is configured' {
        $env:AZAPPSERVICEPROMOTION_CONFIG = Join-Path $TestDrive 'empty.json'
        { Export-AppServiceSetting -Path (Join-Path $TestDrive 'export9.json') } | Should -Throw '*source App Service is not fully specified*'
    }
}

Describe 'Settings file validation' {
    It 'rejects duplicate names (case-insensitive)' {
        $f = New-SettingsFile -Path (Join-Path $TestDrive 'dup.json') -AppSettings @(@{ name = 'A'; value = '1' }, @{ name = 'a'; value = '2' })
        { InModuleScope AzAppServicePromotion -Parameters @{ f = $f } { param($f) Read-PromotionSettingsFile -Path $f } } | Should -Throw '*duplicate*'
    }

    It 'rejects invalid connection string types' {
        $f = New-SettingsFile -Path (Join-Path $TestDrive 'type.json') -ConnectionStrings @(@{ name = 'Db'; value = 'x'; type = 'Oracle' })
        { InModuleScope AzAppServicePromotion -Parameters @{ f = $f } { param($f) Read-PromotionSettingsFile -Path $f } } | Should -Throw '*invalid type*'
    }

    It 'rejects invalid JSON' {
        $f = Join-Path $TestDrive 'bad.json'
        Set-Content $f '{ not json'
        { InModuleScope AzAppServicePromotion -Parameters @{ f = $f } { param($f) Read-PromotionSettingsFile -Path $f } } | Should -Throw '*not valid JSON*'
    }

    It 'defaults missing type to Custom and missing slotSetting to false' {
        $f = New-SettingsFile -Path (Join-Path $TestDrive 'defaults.json') -AppSettings @(@{ name = 'A'; value = '1' }) -ConnectionStrings @(@{ name = 'Db'; value = 'x' })
        $r = InModuleScope AzAppServicePromotion -Parameters @{ f = $f } { param($f) Read-PromotionSettingsFile -Path $f }
        $r.AppSettings[0].slotSetting | Should -BeFalse
        $r.ConnectionStrings[0].type | Should -Be 'Custom'
    }
}

Describe 'Compare-AppServiceSetting' {
    BeforeEach {
        $env:AZAPPSERVICEPROMOTION_CONFIG = Join-Path $TestDrive ("config-{0}.json" -f [guid]::NewGuid())
        Set-AppServicePromotionDestination -Name prod -Subscription 'dst-sub' -ResourceGroupName 'rg-dst' -AppName 'app-dst'
        Register-AzMock -AppSettings @{ API_URL = 'https://old'; SAME = 'x'; DEST_ONLY = 'keep-me'; STICKY = 's' } `
            -ConnectionStrings @(@{ Name = 'Db'; Value = 'Server=prod;'; Type = 'SQLAzure' }) -StickyApp @('STICKY')
        $script:file = New-SettingsFile -Path (Join-Path $TestDrive 'cmp.json') -AppSettings @(
            @{ name = 'API_URL'; value = 'https://new'; slotSetting = $false },
            @{ name = 'SAME'; value = 'x'; slotSetting = $false },
            @{ name = 'NEW_ONE'; value = 'n'; slotSetting = $false },
            @{ name = 'STICKY'; value = 's'; slotSetting = $false },
            @{ name = 'KV'; value = '@Microsoft.KeyVault(SecretUri=https://kv/secrets/a)'; slotSetting = $false }
        ) -ConnectionStrings @(@{ name = 'Db'; value = 'Server=prod;'; type = 'SQLServer'; slotSetting = $false })
    }

    It 'reports Add / Change / Keep in Merge mode' {
        $d = Compare-AppServiceSetting -Path $script:file -Destination prod
        ($d | Where-Object Name -eq 'NEW_ONE').Action | Should -Be 'Add'
        ($d | Where-Object Name -eq 'API_URL').Action | Should -Be 'Change'
        ($d | Where-Object Name -eq 'API_URL').Changes | Should -Be 'Value'
        ($d | Where-Object Name -eq 'STICKY').Changes | Should -Be 'SlotSetting'
        ($d | Where-Object Name -eq 'Db').Changes | Should -Be 'Type'
        ($d | Where-Object Name -eq 'DEST_ONLY').Action | Should -Be 'Keep'
        $d.Name | Should -Not -Contain 'SAME'
        $d.Action | Should -Not -Contain 'Remove'
    }

    It 'reports Remove in Replace mode and returns unchanged with -IncludeUnchanged' {
        $d = Compare-AppServiceSetting -Path $script:file -Destination prod -Mode Replace -IncludeUnchanged
        ($d | Where-Object Name -eq 'DEST_ONLY').Action | Should -Be 'Remove'
        ($d | Where-Object Name -eq 'SAME').Action | Should -Be 'Unchanged'
    }

    It 'masks values by default but shows Key Vault references' {
        $d = Compare-AppServiceSetting -Path $script:file -Destination prod
        ($d | Where-Object Name -eq 'API_URL').NewValue | Should -BeLike '*chars*'
        ($d | Where-Object Name -eq 'API_URL').NewValue | Should -Not -BeLike '*new*'
        ($d | Where-Object Name -eq 'KV').NewValue | Should -BeLike '@Microsoft.KeyVault(*'
        $shown = Compare-AppServiceSetting -Path $script:file -Destination prod -ShowValues
        ($shown | Where-Object Name -eq 'API_URL').NewValue | Should -Be 'https://new'
    }

    It 'uses the destination subscription, restores context and never writes' {
        Compare-AppServiceSetting -Path $script:file -Destination prod | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Subscription -eq 'dst-sub' }
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Context.Name -eq 'prior' }
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebApp -Times 0 -Exactly
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebAppSlotConfigName -Times 0 -Exactly
    }

    It 'accepts explicit parameters without a profile' {
        Compare-AppServiceSetting -Path $script:file -Subscription 's2' -ResourceGroupName 'rg2' -AppName 'a2' -Slot 'qa' | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Get-AzWebAppSlot -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg2' -and $Name -eq 'a2' -and $Slot -eq 'qa' }
    }

    It 'fails for an unknown profile' {
        { Compare-AppServiceSetting -Path $script:file -Destination nope } | Should -Throw '*not found*'
    }
}

Describe 'Publish-AppServiceSetting' {
    BeforeEach {
        $env:AZAPPSERVICEPROMOTION_CONFIG = Join-Path $TestDrive ("config-{0}.json" -f [guid]::NewGuid())
        Set-AppServicePromotionDestination -Name prod -Subscription 'dst-sub' -ResourceGroupName 'rg-dst' -AppName 'app-dst'
        Register-AzMock -AppSettings @{ API_URL = 'https://old'; DEST_ONLY = 'keep-me'; OTHER_STICKY = 'o' } `
            -ConnectionStrings @(@{ Name = 'Db'; Value = 'Server=old;'; Type = 'SQLAzure' }) -StickyApp @('OTHER_STICKY')
        $script:file = New-SettingsFile -Path (Join-Path $TestDrive 'pub.json') -AppSettings @(
            @{ name = 'API_URL'; value = 'https://new'; slotSetting = $false },
            @{ name = 'NEW_STICKY'; value = 'n'; slotSetting = $true }
        ) -ConnectionStrings @(@{ name = 'Db'; value = 'Server=new;'; type = 'SQLAzure'; slotSetting = $false })
    }

    It 'changes nothing with -WhatIf' {
        $r = Publish-AppServiceSetting -Path $script:file -Destination prod -WhatIf
        $r.Applied | Should -BeFalse
        $r.Added | Should -Be 1
        $r.Changed | Should -Be 2
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebApp -Times 0 -Exactly
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebAppSlotConfigName -Times 0 -Exactly
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Context.Name -eq 'prior' }
    }

    It 'merges client-side, keeping destination-only settings' {
        $r = Publish-AppServiceSetting -Path $script:file -Destination prod -Force
        $r.Applied | Should -BeTrue
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebApp -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'rg-dst' -and $Name -eq 'app-dst' -and
            $AppSettings.Count -eq 4 -and $AppSettings['API_URL'] -eq 'https://new' -and
            $AppSettings['DEST_ONLY'] -eq 'keep-me' -and $AppSettings['NEW_STICKY'] -eq 'n' -and
            $ConnectionStrings['Db'].Type -eq 'SQLAzure' -and $ConnectionStrings['Db'].Value -eq 'Server=new;'
        }
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Subscription -eq 'dst-sub' }
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Context.Name -eq 'prior' }
    }

    It 'removes destination-only settings in Replace mode' {
        Publish-AppServiceSetting -Path $script:file -Destination prod -Mode Replace -Force | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebApp -Times 1 -Exactly -ParameterFilter {
            $AppSettings.Count -eq 2 -and -not $AppSettings.ContainsKey('DEST_ONLY')
        }
    }

    It 'adds new sticky names while preserving existing ones' {
        Publish-AppServiceSetting -Path $script:file -Destination prod -Force | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebAppSlotConfigName -Times 1 -Exactly -ParameterFilter {
            $ResourceGroupName -eq 'rg-dst' -and $Name -eq 'app-dst' -and
            @($AppSettingNames).Count -eq 2 -and $AppSettingNames -contains 'OTHER_STICKY' -and $AppSettingNames -contains 'NEW_STICKY' -and
            $null -eq $ConnectionStringNames
        }
    }

    It 'uses RemoveAllAppSettingNames when the sticky list becomes empty' {
        $f = New-SettingsFile -Path (Join-Path $TestDrive 'unstick.json') -AppSettings @(@{ name = 'OTHER_STICKY'; value = 'o'; slotSetting = $false })
        Publish-AppServiceSetting -Path $f -Destination prod -Force | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebAppSlotConfigName -Times 1 -Exactly -ParameterFilter { $RemoveAllAppSettingNames }
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebApp -Times 0 -Exactly
    }

    It 'targets Set-AzWebAppSlot for a slot (profile overridden by explicit -Slot)' {
        Publish-AppServiceSetting -Path $script:file -Destination prod -Slot staging -Force | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Get-AzWebAppSlot -Times 1 -Exactly -ParameterFilter { $Slot -eq 'staging' }
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebAppSlot -Times 1 -Exactly -ParameterFilter { $Slot -eq 'staging' -and $Name -eq 'app-dst' }
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebApp -Times 0 -Exactly
    }

    It 'does nothing when there are no changes' {
        $f = New-SettingsFile -Path (Join-Path $TestDrive 'same.json') -AppSettings @(@{ name = 'API_URL'; value = 'https://old'; slotSetting = $false })
        $r = Publish-AppServiceSetting -Path $f -Destination prod -Force
        $r.Applied | Should -BeFalse
        $r.Kept | Should -Be 3   # DEST_ONLY, OTHER_STICKY, Db
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebApp -Times 0 -Exactly
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebAppSlotConfigName -Times 0 -Exactly
    }

    It 'only sends the changed collection' {
        $f = New-SettingsFile -Path (Join-Path $TestDrive 'apponly.json') -AppSettings @(@{ name = 'API_URL'; value = 'https://x'; slotSetting = $false })
        Publish-AppServiceSetting -Path $f -Destination prod -Force | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzWebApp -Times 1 -Exactly -ParameterFilter {
            $null -ne $AppSettings -and $null -eq $ConnectionStrings
        }
    }

    It 'restores the context when applying fails' {
        Mock -ModuleName AzAppServicePromotion Set-AzWebApp { throw 'denied' }
        { Publish-AppServiceSetting -Path $script:file -Destination prod -Force } | Should -Throw '*denied*'
        Should -Invoke -ModuleName AzAppServicePromotion Set-AzContext -Times 1 -Exactly -ParameterFilter { $Context.Name -eq 'prior' }
    }

    It 'warns when destination equals the export source' {
        Mock -ModuleName AzAppServicePromotion Write-Warning { }
        $f = New-SettingsFile -Path (Join-Path $TestDrive 'self.json') -AppSettings @(@{ name = 'A'; value = '1' }) `
            -Source @{ subscriptionId = 'dst-sub'; resourceGroupName = 'rg-dst'; appName = 'app-dst'; slot = $null }
        Publish-AppServiceSetting -Path $f -Destination prod -WhatIf | Out-Null
        Should -Invoke -ModuleName AzAppServicePromotion Write-Warning -ParameterFilter { $Message -like '*same App Service*' }
    }

    It 'declares SupportsShouldProcess with high impact' {
        $cmd = Get-Command Publish-AppServiceSetting
        $cmd.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $cmd.Parameters.ContainsKey('Confirm') | Should -BeTrue
        $attr = $cmd.ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
        $attr.ConfirmImpact | Should -Be 'High'
    }
}
