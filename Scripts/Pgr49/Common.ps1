#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PgrFork = 'https://github.com/quyen123ab/InfiniteLoop.git'
$PgrUpstream = 'https://github.com/reiserFSs/InfiniteLoop.git'
$PgrBranch = 'integration/pgr49-gmtools'
$PgrBaseline = '8b7683525987f4534fff02972dadc6758271da59'
$PgrTarget = 'x86_64-pc-windows-msvc'

function Write-PgrFailure {
    param([System.Management.Automation.ErrorRecord]$Record, [string]$Log)
    $details = $Record | Format-List * -Force | Out-String -Width 240
    Add-Content -LiteralPath $Log -Value ($details + $Record.Exception.ToString())
}

function Invoke-PgrNative {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$Log,
        [switch]$AllowFailure,
        [int]$TimeoutSeconds = 1800
    )
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stdout = ''
    $stderr = ''
    Add-Content -LiteralPath $Log -Value ("[{0:o}] {1} {2}" -f [DateTimeOffset]::Now, $Executable, ($Arguments -join ' '))
    try {
        if (!$process.Start()) { throw "Could not start $Executable" }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        $timedOut = !$process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        $stderr = $errTask.GetAwaiter().GetResult()
        $code = $process.ExitCode
        Add-Content -LiteralPath $Log -Value "exit $code"
        if ($timedOut) { throw "$Executable timed out after $TimeoutSeconds seconds. See $Log" }
    } finally {
        $process.Dispose()
        Add-Content -LiteralPath $Log -Value @('stdout', $stdout, 'stderr', $stderr)
    }
    if ($code -ne 0 -and !$AllowFailure) { throw "$Executable exited $code. See $Log" }
    [pscustomobject]@{
        ExitCode = $code
        Stdout = $stdout.Trim()
        Stderr = $stderr.Trim()
    }
}

function Invoke-PgrGit {
    param([string]$Tree, [string]$Log, [string[]]$Arguments, [switch]$AllowFailure)
    $gitOptions = @()
    if ($IsWindows) { $gitOptions = @('-c', 'http.sslBackend=schannel') }
    Invoke-PgrNative git ($gitOptions + $Arguments) $Tree $Log -AllowFailure:$AllowFailure
}

function Read-PgrManifest {
    param([string]$Directory)
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $Directory 'release.json') | ConvertFrom-Json -AsHashtable
    if ($manifest.schemaVersion -ne 1 -or $manifest.repository -cne $PgrFork -or $manifest.branch -cne $PgrBranch -or
        $manifest.commit -cnotmatch '^[a-f0-9]{40}$' -or $manifest.version -cnotmatch '^\d+\.\d+\.\d+-pgr49\.\d+$') {
        throw "Invalid paired release identity in $Directory"
    }
    return $manifest
}

function Get-PgrFileHashes {
    param([string]$Directory, [string[]]$Exclude = @())
    $directory = [IO.Path]::GetFullPath($Directory)
    $rootItem = Get-Item -Force -LiteralPath $directory
    if ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point in release: $directory" }
    $hashes = [ordered]@{}
    $children = Get-ChildItem -Force -Recurse -LiteralPath $directory | Sort-Object FullName
    foreach ($child in $children) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point in release: $($child.FullName)" }
        if ($child.PSIsContainer) { continue }
        $relative = [IO.Path]::GetRelativePath($directory, $child.FullName).Replace('\', '/')
        if ($relative -in $Exclude) { continue }
        $hashes.Add($relative, (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    return $hashes
}

function Assert-PgrRelease {
    param([string]$Directory)
    $manifest = Read-PgrManifest $Directory
    $hashes = Get-PgrFileHashes $Directory @('release.json')
    if ($manifest.files.Count -ne $hashes.Count) { throw "Manifest file count differs at $Directory" }
    foreach ($entry in $hashes.GetEnumerator()) {
        if ($manifest.files[$entry.Key] -cne $entry.Value) { throw "SHA-256 mismatch for $($entry.Key)" }
    }
    foreach ($required in @(
        'AscNetLauncher.exe', 'launcher.json', 'supported-client.json',
        'background.bmp', 'background.mp4', 'background.wav',
        'server/AscNet.dll', 'server/Configs/client_shops.json', 'patch/version.dll',
        'patch/lucia.dll', 'patch/KRSDK.dll', 'patch/libraries.txt',
        'Mods/core/mod.json', 'Mods/gm-menu/mod.json', 'verification.json'
    )) {
        if (!$hashes.Contains($required)) { throw "Release is missing $required" }
    }
    $verified = Get-Content -Raw -LiteralPath (Join-Path $Directory 'verification.json') | ConvertFrom-Json -AsHashtable
    if ($verified.commit -cne $manifest.commit -or $verified.status -cne 'validated' -or
        $verified.unexpectedFailures.Count -ne 0 -or $verified.focusedPassed -lt 1) {
        throw 'Release lacks matching passing regression evidence'
    }
    return $manifest
}

function Write-PgrJson {
    param([string]$Path, $Value)
    $json = ($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine
    [IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}
