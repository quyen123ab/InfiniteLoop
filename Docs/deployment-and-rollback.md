# Deployment and rollback

Use PowerShell 7 and a dedicated `InfiniteLoop-Pgr49` installation directory. The default is `%LOCALAPPDATA%\InfiniteLoop-Pgr49`. A separate launcher installation can keep using its existing files. Close the launcher and PGR before switching game patches or starting a different release.

```powershell
$sha = (Get-Content "$zip.sha256").Split(' ')[0]
./Scripts/Pgr49/Deploy-Pgr49Release.ps1 -Zip $zip -Sha256 $sha
./Scripts/Pgr49/Start-Pgr49.ps1
```

To keep an existing `AscNetLauncher.exe` path, supply it as `-LauncherPath` and set `-InstallRoot` to the adjacent `InfiniteLoop-Pgr49` directory. Deployment backs up the original executable, accompanying assets and legacy server/patch before replacing the executable. Opening that same path starts the active paired release. Later upgrades only change the release pointer. Use `Rollback-Pgr49Release.ps1 -InstallRoot $install -RestoreOriginalLauncher` to restore the original executable from its verified backup.

Get the SHA-256 from the build output or trusted release handoff. Deployment verifies it before extracting the ZIP. It verifies package files and regression evidence, creates a verified backup of the active release and copies its settings and server config, then replaces `active.json` atomically. Invalid ZIPs or failed backups leave the active pointer in place. Each release lives under `versions` with its own launcher, server, patch, mods and verification evidence. The first activation has no previous custom release.

Open the launcher using `Start-Pgr49.ps1`. On the first launch, select the game folder and run Setup. Repeat Setup after changing versions if the launcher reports that its client patch needs updating. Settings and player data use the same persistent paths across releases. For a site-specific server file, commit the customization to the canonical branch and include it in the next validated build. Existing external server folders remain available as legacy installs.

```powershell
./Scripts/Pgr49/Rollback-Pgr49Release.ps1
```

Specify `-GameDirectory $game` to run the previous release's Setup before switching the pointer. This reinstalls that release's client patch, including a previous patch version if the saved originals and client build still match. If the game client has itself upgraded beyond the previous release's supported builds, use a compatible game copy. Rollback preserves the current persistent config and player data, and it records the prior current release as the next rollback target.

Deployment backups preserve all versioned release files and copies of launcher/server configuration. They are release backups. The scripts leave the launcher-managed MongoDB directory outside the deployment transaction.
