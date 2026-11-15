#requires -Version 7.0
[CmdletBinding()]
param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'InfiniteLoop-Pgr49'))
. "$PSScriptRoot/Deployment.ps1"
$root = Get-PgrInstallRoot $InstallRoot
$state = Get-PgrDeploymentState $root
if (!$state) { throw 'Deploy a validated PGR 4.9 release before starting the launcher' }
$release = Get-PgrInstalledRelease $root $state.current
Start-Process -FilePath (Join-Path $release 'AscNetLauncher.exe') -WorkingDirectory $release
