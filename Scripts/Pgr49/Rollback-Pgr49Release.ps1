#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'InfiniteLoop-Pgr49'),
    [string]$GameDirectory,
    [switch]$RestoreOriginalLauncher
)
. "$PSScriptRoot/Deployment.ps1"
$root = Get-PgrInstallRoot $InstallRoot
$lock = Open-PgrDeploymentLock $root
$log = Join-Path $root 'deployment.log'
try {
    if ($RestoreOriginalLauncher) {
        Restore-PgrLauncherEntryPoint $root
        return
    }
    $state = Get-PgrDeploymentState $root
    if (!$state -or !$state.previous) { throw 'No previous custom release has been recorded' }
    $release = Get-PgrInstalledRelease $root $state.previous
    Assert-PgrRelease $release | Out-Null
    if ($GameDirectory) {
        $game = (Resolve-Path -LiteralPath $GameDirectory).Path
        Invoke-PgrNative (Join-Path $release 'AscNetLauncher.exe') @('--setup',$game) $release $log | Out-Null
    }
    Set-PgrDeploymentState $root $state.previous $state.current
    Add-Content -LiteralPath $log -Value "Rolled back to $($state.previous)"
    Write-Host "Rolled back to $($state.previous)"
} catch {
    Write-PgrFailure $_ $log
    throw
} finally {
    $lock.Dispose()
}
