<#
.SYNOPSIS
    Makes Az.Accounts / Az.Websites resolvable without installing the real modules.

.DESCRIPTION
    The module manifest declares Az.Accounts and Az.Websites (>= 2.0.0) as RequiredModules, so
    Import-Module and Test-ModuleManifest fail when they are not installed. For tests and CI we only
    need the commands to exist so they can be mocked. For each module that is not already available,
    this script writes a minimal stub module (version 2.0.0) to a temp folder and prepends that folder
    to $env:PSModulePath for the current process. Real installed modules are always preferred.

    Returns the stub root folder, or nothing if no stubs were needed.
#>
[CmdletBinding()]
[OutputType([string])]
param()

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

$needed = @($stubs.Keys | Sort-Object | Where-Object {
        -not (Get-Module -ListAvailable -Name $_ | Where-Object { $_.Version -ge [version]'2.0.0' })
    })
if ($needed.Count -eq 0) {
    Write-Verbose 'Az.Accounts and Az.Websites are installed; no stubs needed.'
    return
}

$stubRoot = Join-Path ([IO.Path]::GetTempPath()) ('azasp-stubs-' + [guid]::NewGuid())
foreach ($name in $needed) {
    $dir = Join-Path (Join-Path $stubRoot $name) '2.0.0'
    $null = New-Item -ItemType Directory -Path $dir -Force
    Set-Content -Path (Join-Path $dir "$name.psm1") -Value $stubs[$name]
    New-ModuleManifest -Path (Join-Path $dir "$name.psd1") -RootModule "$name.psm1" -ModuleVersion '2.0.0' -FunctionsToExport '*'
    Write-Verbose "Created stub module $name at $dir"
}
$env:PSModulePath = $stubRoot + [IO.Path]::PathSeparator + $env:PSModulePath
$stubRoot
