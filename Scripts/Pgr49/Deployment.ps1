#requires -Version 7.0
. "$PSScriptRoot/Common.ps1"

function Get-PgrInstallRoot {
    param([string]$InstallRoot)
    $root = [IO.Path]::GetFullPath($InstallRoot)
    if ($root -eq [IO.Path]::GetPathRoot($root) -or [IO.Path]::GetFileName($root.TrimEnd('\','/')) -ne 'InfiniteLoop-Pgr49') {
        throw 'Use a dedicated install directory named InfiniteLoop-Pgr49'
    }
    if (Test-Path -LiteralPath (Join-Path $root 'AscNetLauncher.exe')) {
        throw 'The install root must be separate from an existing launcher folder'
    }
    foreach ($directory in @('AscNetLauncher','AscNet')) {
        $profile = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA $directory))
        if ($root.StartsWith($profile + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Keep the release install outside the launcher profile and runtime'
        }
    }
    $parent = [IO.DirectoryInfo]::new($root)
    while ($null -ne $parent) {
        if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Install root includes a reparse point: $($parent.FullName)"
        }
        $parent = $parent.Parent
    }
    return $root
}

function Open-PgrDeploymentLock {
    param([string]$Root)
    [IO.File]::Open((Join-Path $Root 'deployment.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function Get-PgrDeploymentState {
    param([string]$Root)
    $file = Join-Path $Root 'active.json'
    if (!(Test-Path -LiteralPath $file)) { return }
    $state = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json -AsHashtable
    if ($state.schemaVersion -ne 1 -or !$state.current) { throw "Invalid release state at $file" }
    return $state
}

function Get-PgrInstalledRelease {
    param([string]$Root, [string]$Id)
    if ($Id -cnotmatch '^InfiniteLoop-\d+\.\d+\.\d+-pgr49\.\d+-[a-f0-9]{12}-win-x64$') {
        throw "Invalid release identifier: $Id"
    }
    $versions = Join-Path $Root 'versions'
    if ((Get-Item -LiteralPath $versions -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'versions directory is a reparse point'
    }
    return Join-Path $versions $Id
}

function Set-PgrDeploymentState {
    param([string]$Root, [string]$Current, [string]$Previous)
    $target = Join-Path $Root 'active.json'
    $pending = Join-Path $Root ('.active-' + [guid]::NewGuid().ToString('N') + '.json')
    $json = @{ schemaVersion = 1; current = $Current; previous = $Previous } | ConvertTo-Json
    $stream = [IO.File]::Open($pending, [IO.FileMode]::CreateNew)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes)
        $stream.Flush($true)
    } finally {
        $stream.Dispose()
    }
    if (Test-Path -LiteralPath $target) { [IO.File]::Replace($pending, $target, [NullString]::Value) }
    else { [IO.File]::Move($pending, $target) }
}

function Backup-PgrRelease {
    param([string]$Root, $State)
    if (!$State) { return }
    $active = Get-PgrInstalledRelease $Root $State.current
    Assert-PgrRelease $active | Out-Null
    $backup = [IO.Directory]::CreateDirectory((Join-Path $Root ('backups/' + [guid]::NewGuid().ToString('N')))).FullName
    Copy-Item -LiteralPath $active -Destination (Join-Path $backup $State.current) -Recurse
    Assert-PgrRelease (Join-Path $backup $State.current) | Out-Null
    Copy-Item -LiteralPath (Join-Path $Root 'active.json') -Destination $backup
    # These files live outside the release and are read-only inputs to this backup.
    $local = Join-Path $env:LOCALAPPDATA 'AscNetLauncher/local'
    foreach ($entry in @{ 'server-config.json' = (Join-Path $local 'config.json')
        'paired-runtime.json' = (Join-Path $local 'paired-runtime.json')
        'launcher-settings.json' = (Join-Path $env:LOCALAPPDATA 'AscNet/Launcher/settings.json') }.GetEnumerator()) {
        if (Test-Path -LiteralPath $entry.Value -PathType Leaf) {
            Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $backup $entry.Key)
        }
    }
    Write-Host "Deployment backup saved at $backup"
}

function Install-PgrLauncherEntryPoint {
    param([string]$Root, [string]$LauncherPath, [string]$Release)
    $path = [IO.Path]::GetFullPath($LauncherPath)
    $directory = [IO.Path]::GetDirectoryName($path)
    if ([IO.Path]::GetFileName($path) -ine 'AscNetLauncher.exe' -or
        [IO.Path]::GetFullPath((Join-Path $directory 'InfiniteLoop-Pgr49')) -ine $Root) {
        throw 'The launcher entry point must be AscNetLauncher.exe beside the InfiniteLoop-Pgr49 install directory'
    }
    if (Test-Path -LiteralPath (Join-Path $directory 'release.json')) {
        throw 'The requested entry point is already part of a standalone release'
    }
    $original = Get-Item -Force -LiteralPath $path
    if ($original.PSIsContainer -or ($original.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "The original launcher is not a regular file: $path"
    }
    $observedHash = (Get-FileHash -LiteralPath $path).Hash
    $originFile = Join-Path $Root 'original-launcher.json'
    if (Test-Path -LiteralPath $originFile) {
        $origin = Get-Content -Raw -LiteralPath $originFile | ConvertFrom-Json -AsHashtable
        if ($origin.path -ine $path) { throw 'The existing launcher entry point refers to another path' }
        if ($observedHash -ceq $origin.entrySha256) { return }
        if ($observedHash -cne $origin.sha256) { throw 'The current launcher differs from both saved entry points' }
    } else {
        $backup = Backup-PgrOriginalLauncher $Root $path
        $origin = @{ path = $path; backup = $backup; sha256 = $observedHash; entrySha256 = '' }
    }
    $pending = Join-Path $directory ('.ascnet-entry-' + [guid]::NewGuid().ToString('N') + '.exe')
    Copy-Item -LiteralPath (Join-Path $Release 'AscNetLauncher.exe') -Destination $pending
    $origin.entrySha256 = (Get-FileHash -LiteralPath $pending).Hash
    Write-PgrJson $originFile $origin
    if ((Get-FileHash -LiteralPath $path).Hash -cne $observedHash) { throw 'The original launcher changed during backup' }
    [IO.File]::Replace($pending, $path, [NullString]::Value)
    Write-Host "Original launcher backup saved at $($origin.backup)"
}

function Backup-PgrOriginalLauncher {
    param([string]$Root, [string]$LauncherPath)
    $directory = [IO.Path]::GetDirectoryName($LauncherPath)
    $backup = [IO.Directory]::CreateDirectory((Join-Path $Root ("backups/original-$([guid]::NewGuid().ToString('N'))"))).FullName
    foreach ($name in @('AscNetLauncher.exe','launcher.json','supported-client.json','setup-local.ps1','background.bmp','background.mp4','background.wav')) {
        $source = Join-Path $directory $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            $destination = Join-Path $backup $name
            Copy-Item -LiteralPath $source -Destination $destination
            if ((Get-FileHash -LiteralPath $source).Hash -cne (Get-FileHash -LiteralPath $destination).Hash) {
                throw "Original launcher backup failed verification for $name"
            }
        }
    }
    $local = Join-Path $env:LOCALAPPDATA 'AscNetLauncher/local'
    $legacyState = Join-Path $local 'build-state.json'
    foreach ($entry in @{ 'server-config.json' = (Join-Path $local 'config.json')
        'build-state.json' = $legacyState
        'launcher-settings.json' = (Join-Path $env:LOCALAPPDATA 'AscNet/Launcher/settings.json') }.GetEnumerator()) {
        if (Test-Path -LiteralPath $entry.Value -PathType Leaf) {
            Copy-Item -LiteralPath $entry.Value -Destination (Join-Path $backup $entry.Key)
        }
    }
    # Legacy server and patch directories remain in place. Snapshot the versions currently referenced by Setup.
    if (Test-Path -LiteralPath $legacyState -PathType Leaf) {
        $build = Get-Content -Raw -LiteralPath $legacyState | ConvertFrom-Json -AsHashtable
        foreach ($entry in @{ server = $build.serverDirectory; patch = $build.patchDirectory }.GetEnumerator()) {
            $source = [IO.Path]::GetFullPath($entry.Value)
            if (!$source.StartsWith([IO.Path]::GetFullPath($local) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Legacy $($entry.Key) path is outside the launcher runtime"
            }
            $before = Get-PgrFileHashes $source
            $destination = Join-Path $backup $entry.Key
            Copy-Item -LiteralPath $source -Destination $destination -Recurse
            $after = Get-PgrFileHashes $destination
            if ($before.Count -ne $after.Count) { throw "Legacy $($entry.Key) backup file count differs" }
            foreach ($file in $before.GetEnumerator()) {
                if ($after[$file.Key] -cne $file.Value) { throw "Legacy backup SHA-256 mismatch for $($file.Key)" }
            }
        }
    }
    return $backup
}

function Restore-PgrLauncherEntryPoint {
    param([string]$Root)
    $original = Get-Content -Raw -LiteralPath (Join-Path $Root 'original-launcher.json') | ConvertFrom-Json -AsHashtable
    $path = [IO.Path]::GetFullPath($original.path)
    $directory = [IO.Path]::GetDirectoryName($path)
    if ((Join-Path $directory 'InfiniteLoop-Pgr49') -ine $Root -or [IO.Path]::GetFileName($path) -ine 'AscNetLauncher.exe') {
        throw 'The original launcher path is outside the deployment'
    }
    $backup = [IO.Path]::GetFullPath($original.backup)
    if ([IO.Path]::GetDirectoryName($backup) -ine (Join-Path $Root 'backups')) { throw 'Invalid original launcher backup directory' }
    $source = Join-Path $backup 'AscNetLauncher.exe'
    if ((Get-FileHash -LiteralPath $source).Hash -cne $original.sha256) { throw 'Original launcher backup SHA-256 mismatch' }
    if ((Get-FileHash -LiteralPath $path).Hash -cnotin @($original.sha256,$original.entrySha256)) {
        throw 'The current launcher differs from both saved entry points'
    }
    $pending = Join-Path $directory ('.ascnet-restore-' + [guid]::NewGuid().ToString('N') + '.exe')
    Copy-Item -LiteralPath $source -Destination $pending
    [IO.File]::Replace($pending, $path, [NullString]::Value)
    Write-Host "Restored the original launcher at $path"
}
