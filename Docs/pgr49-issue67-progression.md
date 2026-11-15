# PGR 4.9 progression verification

Issue #67 work is based on draft PR #66 at `8b7683525987f4534fff02972dadc6758271da59`. The launcher installation uses the #66 shop preload fix, the login weapon repair, the CUB EXP fix, and six simulator exchange offers in Material Shop 1422. [Issue #67](https://github.com/reiserFSs/InfiniteLoop/issues/67) · [Draft PR #66](https://github.com/reiserFSs/InfiniteLoop/pull/66)

## Memory Bulk Upgrade

The Memory screen first loads shop 1422 together with Command Bureau Personal Shop 4001. The captured `20063226` response made the client skip the screen-open callback. PR #66 preserves Guild checks on individual shop lookups and purchases and allows the accessible shop in the mixed preload. The staged and installed server includes that fix.

The saved game logs show three successful Memory feeds at 20:03:28, 20:03:41 and 20:03:51. These are separate observations from the old build. The logs have no trace that ties them to a single Bulk Upgrade click, and the reported account's loadout and client callback state at the failing click are unknown.

One reproducible Memory failure occurs during login repair. When a legacy loadout has an incompatible weapon and needs its default weapon restored, `Character.NormalizeCharactersForCurrentTables` previously cleared `CharacterId` on the worn Memories as well. The gear remained individually upgradeable in inventory, while the bulk planner lost its worn slots. The regression reproduced the lost assignment on the unchanged code. The repair now limits the compatibility check and replacement to weapon slots. The repaired loadout kept all six worn Memories across login and the Lua producer sent both intended upgrades. This identifies a server defect for that loadout. The original player's failing click still needs a matching client trace.

The Memory producer is `XUiEquipAwarenessEnhanceMain.OnBtnExecuteCompleteProcessClick` and `XUiEquipAwarenessOneClickPopup.OnBtnConfirmClick`. The popup reads the worn slot map, calls `XUiPanelAwarenessOneClickStrengthen.RefreshStrengthenPreview`, and uses `XEquipStrengthenControl.SimulateAwarenessMaxAchievablePreview` to calculate a common achievable target from the phase caps and one shared material pool. The planner requires six worn slots. Only eligible Memories with nonempty operations become feed tasks. The confirmation also checks the selected resonance module's configuration. The progress popup starts `StartAwarenessStrengthen`, which sends one `EquipOneKeyFeedRequest` per eligible Memory in slot order after its purchases complete. `XEquipAgency.EquipOneKeyFeedRequest` updates the local equip's `Breakthrough`, `Level`, and `Exp` from each successful response. Completing the progress popup dispatches `EVENT_EQUIP_AWARENESS_ENHANCE_REFRESH` to the main screen.

Weapon one-click uses `XUiEquipWeaponOneClickPopup.Refresh` and `XEquipOneClickCultureControl.GetOneClickCultureViewData`, `_BuildModuleDataList`, and `GetOneClickCultureLevelCostList`. It shares equipment strengthening calculations and `EquipOneKeyFeedRequest` with Memory. Its task list adds selected weapon resonance after the feed. CUBs use their own planner, tasks, and RPCs.

## CUB Quick Upgrade

The saved EN game log on 2026-11-13 at 20:07:42 and 20:08:01 shows the CUB level action needing one item `30112`, one `30111`, and 4,000 coins. It displayed 999 of `30112`, 884 of `30111`, and enough coins. The server logged `PartnerLevelUpResponse` code `1` at both attempts. The same request failed against the unchanged PR #66 handler before sending an inventory debit.

The client builds the Level & Overclock plan in `XPartnerOneKeyCultureBaseCostControl`. `XFlowTreeActionPartnerOneKeyLvExpUp` selects EXP from `XPartnerManager.GetExpItemList`. The authored `PartnerDecomposeExpItemRebate` key lists `30111|30112|30113`. The old `PartnerLevelUpRequestHandler` accepted only `30111` and `30113`. The handler now reads the authored list and takes each item's EXP and coin cost from `Item.tsv`. It validates the full set before spending and uses the existing phase caps. Normal feed and Quick Upgrade both send `PartnerLevelUpRequest`. The quick flow follows successful replies with `PartnerBreakThroughRequest` as appropriate. Original reply callbacks update the entity and advance the progress actions.

The exact mixed feed now consumes 4,000 coins and reaches phase 0 Lv.10. Three overclocks and three further feeds bring the fixture to phase 3 Lv.30. The full sequence debited 124,000 coins, one each of `30111` and `30112`, twelve `30113`, 192 `40200`, and 64 `40201`. The regression also covers a normal single-pod feed, the stage cap, insufficient pods, unlisted `30114`, and persisted state.

## Auto Exchange

The EN `ItemAutoExchange` table maps `147066`–`147071` to the six Overclock materials in shop 1422. The 17-offer baseline returned no row for these IDs. The original `XItemManager.GetItemAutoExchangeInfo` therefore returned no route. The Memory preview reproduced an assertion for `40114` before issuing a purchase or feed. Public client data establishes the IDs. The official 4.9 release notes identify the shop and its currency, with no offer-level prices or bundle quantities for these six materials. [EN client mappings](https://github.com/myssal/PGR_Data/blob/de33e494ea090e82dff530d0d115e79d414f0dcf/en/bytes/client/item/itemautoexchange.json) · [Kuro's A Comet's Afterglow release notes](https://pgr.kurogame.net/news/5686)

With the user's authorization, shop 1422 now has 23 offers. The [six simulator offers](pgr49-equipment-one-click.md#simulator-exchange-offers) each grant four items and cost 30–90 tokens (`62738`) per bundle. They are always available, with no purchase limit, discount, gift, or reset. The existing 17 entries and other shops retain their catalog data. `TotalBuyTimes` remains player state. Tests covered all six purchases, exact credits and costs, insufficient funds, an unknown offer, and the no-mutation result of failed purchases. Exact retail economics remain unknown. To reproduce them, obtain the six sanitized goods objects from a successful 4.9 EN `GetShopInfoResponse` for 1422 or a `GetFixedShopListResponse` containing 1422. Include the version, region, date, and any schedule or reset evidence. The [shop investigation](pgr49-equipment-one-click.md#retail-evidence-needed-for-exact-pricing) lists the required fields.

## Verification

The isolated Release server ran original EN Lua callbacks and planners over the real game TCP dispatcher, using a fresh account per scenario. The host supplied Unity rendering, timer, and UI settings bindings. The CUB replay starts from the captured first material plan and uses authored costs for the subsequent phase actions. The weapon replay supplies the selected resonance slot. Server replies and inventory pushes drove the Lua progression and refresh callbacks.

| Scenario | Observed requests and result |
| --- | --- |
| Single Memory | `EquipLevelUpRequest`. One `31204` and 3,000 coins spent. Lv.44 to Lv.45. |
| Two Memories with owned materials | Two `EquipOneKeyFeedRequest` calls. Two `31204` and 6,000 coins spent. Both went from Lv.44 to Lv.45, with two equip update events and a main-screen refresh. |
| Insufficient materials, exchange off | Confirmation disabled. Zero mutation requests. |
| Insufficient EXP materials, exchange on | One `BuyRequest` for `142033`, followed by both feeds. Spent 87 tokens and 6,000 coins, with eight of the ten purchased enhancers left. |
| Insufficient exchange tokens | Confirmation disabled. Zero mutation requests. |
| Legacy weapon | Login restored the default weapon and retained all six Memories. The two eligible Memories upgraded with the same debits as the owned-materials case. |
| Weapon EXP and resonance | `BuyRequest` for `142034`, then feed, then slot 1 resonance. Spent 262 tokens, 3,000 coins, and one `3002`, with nine enhancers left. |
| Two Memory Overclocks | Five purchases before two feeds. Two Memories advanced from Overclock 3 Lv.40 to Overclock 4 Lv.45. Spent 1,042 tokens and 254,000 coins. Two of each purchased material type remained. |
| Weapon Overclock and resonance | Five purchases, one feed, then slot 1 resonance. Weapon advanced from Overclock 3 Lv.40 to Overclock 4 Lv.45. Spent 1,386 tokens, 127,000 coins, and one `3002`. |
| CUB Quick Upgrade | Four `PartnerLevelUpRequest` calls interleaved with three `PartnerBreakThroughRequest` calls. Phase 3 Lv.30 and the exact debits above. |

All ten replay accounts matched the expected progression, resonance state, and inventory after relog and an AscNet process restart. The catalog still returned only authorized shops for a mixed nonmember preload. Windows Sandbox never provided a usable game session, so the rendered game UI has yet to be verified. Sales windows and discounts for the six simulator offers are disabled by policy. Retail schedule and sale behavior was outside the tested data.

Windows .NET SDK 8.0.428 built the test project and published the server. The full solution additionally includes `AscNet.PcapParser`, which needs the .NET Framework 4.8.1 targeting pack. The machine lacks that pack. The server and test builds retain the baseline MessagePack NuGet advisory warnings.

```powershell
dotnet build AscNet.Test/AscNet.Test.csproj -c Release --no-restore
dotnet publish AscNet/AscNet.csproj -c Release --no-restore
Push-Location AscNet.Test/bin/Release/net8.0
dotnet AscNet.Test.dll --simulated-battlefield-compat-only
dotnet AscNet.Test.dll --equipment-one-click-shops-only
dotnet AscNet.Test.dll --equipment-one-click-upgrade-only
dotnet AscNet.Test.dll --shop-compat-only
dotnet AscNet.Test.dll --inventory-equip-compat-only
dotnet AscNet.Test.dll --version49-memory-shop-only
dotnet AscNet.Test.dll --partner-quick-upgrade-only
dotnet AscNet.Test.dll --partner-decompose-compat-only
dotnet AscNet.Test.dll --partner-story-only
dotnet AscNet.Test.dll --keep-going
Pop-Location
```

Use a disposable loopback MongoDB configured in the test output directory. The staged launcher replay and its local scripts are under `E:\InfiniteLoop-Launcher\pgr49-issue67-validation`. The replay takes the saved client Lua, the published launcher server copy, and the isolated MongoDB port. The full differential used the exact PR #66 head as its baseline on this Windows machine.

All nine focused commands passed. The full harness recorded **179 passed and 5 failed**, compared with **178 passed and 5 failed** at the unchanged #66 head. The five failures reproduced with identical messages on the baseline. The Cerberus and Maintainer Action checks require external EN Lua inputs. The Task Progress and Theatre 5 failures concern daily-reset expectations. The Chat check concerns `/item` help text. The earlier #66 run on this machine had recorded 180 passed and three failed before the two daily-reset failures appeared in the current baseline. The report uses the current side-by-side run for regression classification.

## Launcher handoff

Open `E:\InfiniteLoop-Launcher\AscNetLauncher.exe` and press Play. Restart any running local server session so it reloads the catalog. For the original Bulk Upgrade scenario, use a complete six-slot set with at least two Memories below their cap, turn Auto Exchange off, and ensure you already have the required materials. Then test separately with Auto Exchange on and a shortage of Overclock materials. Keep enough item `62738` to cover the exchange. Check the changed levels, then relog. For CUB Quick Upgrade, choose Level & Overclock to Lv.30 with the required materials owned.

If the original no-op recurs, record the time, screen, six worn slots, levels and Overclock phases, selected modules, and Auto Exchange state. The paired local game and server logs can then identify whether the button failed to create a preview, skipped the confirmation, or sent a request that failed. Keep session credentials out of the report.

The launcher uses the same executable and build-state paths. The deployment replaced `AscNet.Common.dll`, `AscNet.GameServer.dll`, their matching symbols, and the server-side catalog. The backup is `E:\InfiniteLoop-Launcher\pgr49-issue67-validation\launcher-live-backup`. Close the launcher and game to roll back. Restore the catalog before restoring the four binaries so the rollback script can verify the original catalog hash.

```powershell
$validation = 'E:\InfiniteLoop-Launcher\pgr49-issue67-validation'
& "$validation\launcher-hotfix\Set-MaterialShopCatalog.ps1" -Restore
& "$validation\launcher-hotfix\Rollback-Server.ps1" -BackupDirectory "$validation\launcher-live-backup"
```
