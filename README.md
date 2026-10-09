# AzAppServicePromotion

PowerShell module that promotes **App Service app settings (environment variables) and connection strings**
from a fixed *source* App Service in one subscription to a *destination* App Service in another subscription,
using Az PowerShell (`Az.Accounts`, `Az.Websites`).

Workflow: **export → edit locally → compare → apply**.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- `Az.Accounts` and `Az.Websites` (declared as `RequiredModules`)
- An Azure login with read access to the source app and write access to the destination app
  (e.g. *Website Contributor*)

```powershell
Install-Module Az.Accounts, Az.Websites -Scope CurrentUser
```

## Install

Copy the `AzAppServicePromotion` folder into a folder on `$env:PSModulePath`
(e.g. `~/Documents/PowerShell/Modules` on Windows, `~/.local/share/powershell/Modules` on Linux/macOS), then:

```powershell
Import-Module AzAppServicePromotion
Get-Command -Module AzAppServicePromotion
```

## Commands

| Command | Purpose |
|---|---|
| `Set-AppServicePromotionConfig` | Save the source subscription / resource group / app / slot (and default export folder). |
| `Get-AppServicePromotionConfig` | Show the saved configuration (path, source, export folder, destination profile names). |
| `Set-AppServicePromotionDestination` | Create/update a named destination profile (subscription, RG, app, slot). |
| `Get-AppServicePromotionDestination` | List destination profiles or get one by name. |
| `Remove-AppServicePromotionDestination` | Delete a destination profile. |
| `Export-AppServiceSetting` | Read the source app's settings + connection strings (+ slot-sticky flags) into an editable JSON file. |
| `Compare-AppServiceSetting` | Show the diff (Add / Change / Remove / Keep) between the file and the destination – read-only. |
| `Publish-AppServiceSetting` | Show the diff and apply the file to the destination (`-WhatIf`, `-Confirm`, `-Force`, `-Mode Merge/Replace`). |

Every command has full help: `Get-Help Publish-AppServiceSetting -Full`.

## Configuration

Stored per user in `$HOME/.azappservicepromotion/config.json`
(override with `$env:AZAPPSERVICEPROMOTION_CONFIG`). It contains only resource identifiers, no secrets.

```json
{
  "Source": { "Subscription": "Contoso-Dev", "Tenant": null, "ResourceGroupName": "rg-web-dev", "AppName": "contoso-web-dev", "Slot": null },
  "ExportDirectory": "C:/promotions",
  "Destinations": {
    "prod": { "Subscription": "Contoso-Prod", "Tenant": null, "ResourceGroupName": "rg-web-prod", "AppName": "contoso-web-prod", "Slot": "staging" }
  }
}
```

`Subscription` may be a subscription ID or name. Explicit parameters on `Export-`, `Compare-` and
`Publish-AppServiceSetting` always override saved values.

## Example workflow

```powershell
Connect-AzAccount

# One-time setup
Set-AppServicePromotionConfig -Subscription 'Contoso-Dev' -ResourceGroupName 'rg-web-dev' -AppName 'contoso-web-dev' -ExportDirectory '~/promotions'
Set-AppServicePromotionDestination -Name prod -Subscription 'Contoso-Prod' -ResourceGroupName 'rg-web-prod' -AppName 'contoso-web-prod'

# 1. Export from the source (context switches to Contoso-Dev and is restored afterwards)
$file = Export-AppServiceSetting -Path ~/promotions/prod-release.json -ExcludeSetting 'WEBSITE_*'

# 2. Edit the values for production
code $file.FullName      # or notepad / vim

# 3. Review the diff (values masked; add -ShowValues to see them)
Compare-AppServiceSetting -Path $file -Destination prod

# 4. Dry run, then apply (prompts for confirmation)
Publish-AppServiceSetting -Path $file -Destination prod -WhatIf
Publish-AppServiceSetting -Path $file -Destination prod

# Or without a profile, into a slot, removing destination-only settings
Publish-AppServiceSetting -Path $file -Subscription 'Contoso-Prod' -ResourceGroupName 'rg-web-prod' `
    -AppName 'contoso-web-prod' -Slot staging -Mode Replace

# 5. Delete the file when done (it contains secrets)
Remove-Item $file
```

## Exported file format

```json
{
  "schemaVersion": 1,
  "metadata": {
    "exportedAtUtc": "2026-10-08T22:00:00.0000000Z",
    "exportedBy": "me@contoso.com",
    "source": { "subscriptionId": "…", "subscriptionName": "Contoso-Dev", "resourceGroupName": "rg-web-dev", "appName": "contoso-web-dev", "slot": null },
    "excluded": [ "WEBSITE_*" ],
    "warning": "This file contains secrets in plain text. Do not commit it to source control."
  },
  "appSettings": [
    { "name": "API_URL", "value": "https://dev.contoso.com", "slotSetting": false },
    { "name": "DbPassword", "value": "@Microsoft.KeyVault(SecretUri=https://kv-dev.vault.azure.net/secrets/db)", "slotSetting": true }
  ],
  "connectionStrings": [
    { "name": "Main", "value": "Server=tcp:dev.database.windows.net;…", "type": "SQLAzure", "slotSetting": false }
  ]
}
```

Edit freely: change values, add or delete entries, flip `slotSetting`. Valid connection string `type`s:
`MySql, SQLServer, SQLAzure, Custom, NotificationHub, ServiceBus, EventHub, ApiHub, DocDb, RedisCache, PostgreSQL`.
The file is validated (duplicate names, types, JSON) before anything touches Azure.

## How applying works

- `Set-AzWebApp` / `Set-AzWebAppSlot -AppSettings/-ConnectionStrings` **replace the whole collection**, so the
  final collection is computed client-side:
  - **Merge** (default): destination settings + file settings (file wins). Destination-only settings are kept (`Keep`).
  - **Replace**: exactly the file. Destination-only settings are deleted (`Remove`).
- A collection is only sent when it actually changed (e.g. untouched connection strings aren't re-written).
- **Slot settings** ("deployment slot setting" / sticky) are applied with `Set-AzWebAppSlotConfigName`. That list is
  shared by the production app and all its slots, so names in the file are made sticky / non-sticky per their
  `slotSetting` flag and **all other existing sticky names are preserved** (even in Replace mode).
- `-WhatIf` shows the diff and what would happen; `-Confirm` (on by default, `ConfirmImpact = High`) prompts;
  `-Force` skips the prompt.
- The Az context is switched to the destination subscription and your previous context is restored afterwards,
  including on errors. A warning is shown if the destination is the same app the file was exported from.
- Saving app settings restarts the destination app (normal App Service behaviour).

## Security

- **The exported file contains secrets in plain text.** Key Vault references (`@Microsoft.KeyVault(...)`) are
  exported as references and are not resolved — make sure the destination app's managed identity can read the
  destination vault, and point references at the destination vault when editing.
- Add exports to `.gitignore`, e.g.:

  ```gitignore
  *-settings-*.json
  promotions/
  ```

- Diff output masks values by default (except Key Vault references); use `-ShowValues` deliberately.
- Delete export files when you're done.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester ./Tests -Output Detailed
```

Tests mock every Az cmdlet (no Azure access needed). If `Az.Accounts`/`Az.Websites` are not installed, the tests
generate stub modules automatically.
