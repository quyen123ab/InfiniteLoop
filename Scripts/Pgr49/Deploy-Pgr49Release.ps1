#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Zip,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256,
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'InfiniteLoop-Pgr49'),
    [string]$LauncherPath
)
. "$PSScriptRoot/Deployment.ps1"
$root = Get-PgrInstallRoot $InstallRoot
[IO.Directory]::CreateDirectory($root) | Out-Null
$lock = Open-PgrDeploymentLock $root
$log = Join-Path $root 'deployment.log'
try {
    $archivePath = (Get-Item -LiteralPath $Zip).FullName
    $staging = [IO.Directory]::CreateDirectory((Join-Path $root ('.staging-' + [guid]::NewGuid().ToString('N')))).FullName
    $archive = [IO.File]::Open($archivePath, 'Open', 'Read', 'Read')
    try {
        $actualHash = (Get-FileHash -InputStream $archive -Algorithm SHA256).Hash
        if ($actualHash -ine $Sha256) { throw "ZIP SHA-256 mismatch for $archivePath" }
        $archive.Position = 0
        $reader = [IO.Compression.ZipArchive]::new($archive, [IO.Compression.ZipArchiveMode]::Read, $true)
        try { [IO.Compression.ZipFileExtensions]::ExtractToDirectory($reader, $staging) }
        finally { $reader.Dispose() }
    } finally {
        $archive.Dispose()
    }
    $manifest = Assert-PgrRelease $staging
    Invoke-PgrNative (Join-Path $staging 'AscNetLauncher.exe') @('--verify-release') $staging $log | Out-Null
    $id = "InfiniteLoop-$($manifest.version)-$($manifest.commit.Substring(0,12))-win-x64"
    [IO.Directory]::CreateDirectory((Join-Path $root 'versions')) | Out-Null
    $final = Get-PgrInstalledRelease $root $id
    if (Test-Path -LiteralPath $final) {
        $existing = Assert-PgrRelease $final
        $oldIdentity = (Get-FileHash -LiteralPath (Join-Path $final 'release.json')).Hash
        $newIdentity = (Get-FileHash -LiteralPath (Join-Path $staging 'release.json')).Hash
        if ($existing.commit -cne $manifest.commit -or $oldIdentity -cne $newIdentity) {
            throw "Existing release $id differs from the staged build. Increment the distribution version."
        }
        $stagedPath = [IO.Path]::GetFullPath($staging)
        if ([IO.Path]::GetDirectoryName($stagedPath) -cne $root -or [IO.Path]::GetFileName($stagedPath) -notmatch '^\.staging-[a-f0-9]{32}$') {
            throw "Invalid staging path $stagedPath"
        }
        Remove-Item -LiteralPath $stagedPath -Recurse
    } else {
        [IO.Directory]::Move($staging, $final)
    }
    $state = Get-PgrDeploymentState $root
    if (!$state -or $id -cne $state.current) {
        Backup-PgrRelease $root $state
        $previous = if ($state) { $state.current } else { '' }
        Set-PgrDeploymentState $root $id $previous
        Add-Content -LiteralPath $log -Value "Activated $id; previous $previous"
    }
    if ($LauncherPath) { Install-PgrLauncherEntryPoint $root $LauncherPath $final }
    Write-Host "Activated $id"
} catch {
    Write-PgrFailure $_ $log
    throw
} finally {
    $lock.Dispose()
}
