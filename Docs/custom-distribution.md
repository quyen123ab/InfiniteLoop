# PGR 4.9 custom distribution

Build from `integration/pgr49-gmtools` in [quyen123ab/InfiniteLoop](https://github.com/quyen123ab/InfiniteLoop/tree/integration/pgr49-gmtools). The launcher, server, client patch and bundled mods ship together. The launcher and server carry the same source commit, which Setup and the managed GM handshake verify. The installer verifies the ZIP SHA-256 and every release file before activating the release.

## Source ownership and provenance

| Source | Commit or archive | Ownership |
| --- | --- | --- |
| InfiniteLoop Launcher 1.0.24 | `716e3f239c0b67b36f9f2c1601e44258a3a45816` | Base for the emulator, launcher, client patch, authoritative tables and existing tests. `Mods/core` and `Mods/gm-menu` are inherited from upstream and are required release inputs. |
| Live GM Player, Guide and Item Finder | `36eeabfad36da25ac50e7313cfba8bd30a31f1ef` (#63) | GM commands, player persistence, item catalog and receipts, launcher GM UI, private managed control, tests and live GM documentation. |
| Local live GM and durable Guide recovery | `5198e287` on `bd31200c8dfe5d7cbb8aed34000c1a240d838087`, with guide work from `eb07f303` | The isolated snapshot has the same tree as PR #63's first commit `446320ac`. Where the overlapping additions conflicted, the merge retained the later Item Finder changes that extend that tree. |
| Memory shop preload | `8b7683525987f4534fff02972dadc6758271da59` (#66) | Named-key shop request DTO, mixed batch shop preload, Guild permissions and equipment/shop regression tests. |
| Issue #67 | `465bd024`, `7449b4d5`, `3528a2e82b9be3d1ab0c0c43bfbc1756605016c3` | CUB EXP and material `30112`, worn Memory normalization, Material Shop 1422 simulator catalog and regressions. |
| Distribution and compatibility | Commits after the feature merges on the canonical branch | `AscNet.Launcher/src/distribution.rs`, launcher Setup/runtime/mod integration, optional external server config, `Scripts/Pgr49`, CI and validation docs. |

The Issue #67 ZIP has SHA-256 `d6c24e0dfac8399c37a7a3700426d536a1272811a41c390dba2f93ce7fa65349`. All 199 entries matched `3528a2e8` after line-ending normalization. Of the 193 test files, 189 matched PR #66. The other four are the runner, the two one-click test partials and the CUB Quick Upgrade partial. The native merge preserved both GM selectors, the local Guide selector and every independent upstream step. The merged `Character.cs` carries the Issue #67 weapon-slot filter and PR #63's journaled item grant save.

The six Material Shop 1422 offers use currency `62738`. They are AscNet simulator policy.

| Goods | Material | Quantity | Cost |
| --- | --- | ---: | ---: |
| 147066 | 40104 | 4 | 35 |
| 147067 | 40103 | 4 | 45 |
| 147068 | 40100 | 4 | 30 |
| 147069 | 40114 | 4 | 70 |
| 147070 | 40113 | 4 | 90 |
| 147071 | 40110 | 4 | 60 |

## Setup and update audit

| Path | Custom release behavior |
| --- | --- |
| Native startup and self-update worker in `main.rs` and `updater.rs` | The default custom build skips the upstream updater, including recovery from a stock updater journal. `Distribution::load` checks the fork, branch and build identity even if someone replaces `launcher.json`. |
| UI source check and CLI/GUI Setup in `ui.rs`, `main.rs`, `local.rs`, `setup.rs` | Both Setup paths load the same release. They provision .NET 8 and the pinned MongoDB executable, prepare the owned patch and save runtime ports. The legacy checkout clone, fetch, fast-forward and server rebuild are outside paired Setup. An intentional `--no-default-features` build with a stock config retains the upstream source path. |
| Server and patch activation | The launcher resolves DLLs, resources and patch files next to its own executable. Its release process builds into staging. The server reads persistent config through `ASCNET_CONFIG_PATH` so starting it does not rewrite the shipped server resource. |
| Client downloads and patch installation | Get Game updates content in the selected game directory. The patch installer checks supported client hashes, tracks its files and keeps game originals. After a client update or release switch, use Setup to apply the patch if the launcher reports that it needs updating. |
| Mod discovery and application | Release `Mods` loads first. Additional mods are read from `%LOCALAPPDATA%\AscNetLauncher\local\Mods` and the retained checkout. `gm-menu` comes from the release. If enabled and its client patch cannot apply, the launcher reports the error before changing installed mod overrides. |
| Settings and data | Launcher settings stay in `%LOCALAPPDATA%\AscNet\Launcher\settings.json` and retain enabled mod IDs, the master toggle and unknown fields. The server config, runtime descriptors, logs and MongoDB data stay in `%LOCALAPPDATA%\AscNetLauncher\local`. Setup reuses the configured ports and MongoDB engine. |

The [upstream workflow](upstream-update-workflow.md) builds candidate releases. [Deployment and rollback](deployment-and-rollback.md) switch versions. The [validation checklist](pgr49-gmtools-validation.md) covers the game client and persistent results.
