# Updating the custom branch

Pin the upstream tag and its full commit. Start the update from the fork's canonical integration branch with PowerShell 7.

```powershell
./Scripts/Pgr49/Update-Pgr49Upstream.ps1 -UpstreamTag $tag -UpstreamCommit $sha `
    -Worktree $candidate -Version $version -MongoExe $mongod `
    -MediaDirectory $media -OutputDirectory $output
```

The script fetches the fork branch and upstream tag, verifies the tag's commit and merges it in an isolated `update/pgr49-<version>` branch. Conflicts stop the update with the Git exit code and affected paths. Resolve and commit the merge in that worktree. Run the same invocation with `-Resume` to validate and package it. Source, test and build stages can also run separately through `Integrate-PGR49-GMTools.ps1`.

Use `Test-Pgr49.ps1` to run the focused selectors and full harness on a disposable MongoDB process on port 27019. It builds the pinned PR #66 baseline and compares the full test names and failure messages. A removed test, missing selector or unexpected failure blocks the release. The mixed-shop test independently checks Guild member and nonmember permissions. The broader Guild suite also runs on both commits and records the known Guild creation assertion when it reproduces on both. The suite leaves its logs and `verification.json` in the output directory.

`Build-Pgr49Release.ps1` requires verification from the same clean commit. It builds x64 Release with .NET 8 and the MSVC Rust target, tests the native launcher, builds the patch and packages the release. Supply a vetted directory with the three launcher background media files. The project uses Cargo lockfiles and a .NET 8 SDK pin.

Perform the Setup/deployment rehearsal and applicable [client checks](pgr49-gmtools-validation.md). Inspect the merge against the ownership table, especially the shared runner, shop handlers, patch/Setup entry points and installed-mod paths. Push by fast-forward to the fork only after review succeeds.

```powershell
git -C $candidate -c http.sslBackend=schannel push https://github.com/quyen123ab/InfiniteLoop.git HEAD:refs/heads/integration/pgr49-gmtools
```

A non-fast-forward rejection means the fork advanced while the candidate was being prepared. Fetch it, merge its new commits, and validate and build again. Deploy via the [versioned release workflow](deployment-and-rollback.md). GitHub Actions runs the automated checks on Windows. Releases require the local media inputs and a reviewed deployment.
