#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+-pgr49\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$Verification,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string]$MediaDirectory,
    [string]$MsBuild
)
. "$PSScriptRoot/Common.ps1"
$tree = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$output = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)).FullName
$log = Join-Path $output "build-$Version.log"

try {
    $commit = (Invoke-PgrGit $tree $log @('rev-parse','HEAD')).Stdout
    if ((Invoke-PgrGit $tree $log @('status','--porcelain')).Stdout) { throw 'The release must be built from a clean commit' }
    foreach ($ancestor in @('716e3f239c0b67b36f9f2c1601e44258a3a45816','36eeabfad36da25ac50e7313cfba8bd30a31f1ef',$PgrBaseline,'3528a2e82b9be3d1ab0c0c43bfbc1756605016c3','5198e287')) {
        Invoke-PgrGit $tree $log @('merge-base','--is-ancestor',$ancestor,$commit) | Out-Null
    }
    $verificationPath = (Get-Item -LiteralPath $Verification).FullName
    $evidence = Get-Content -Raw -LiteralPath $verificationPath | ConvertFrom-Json -AsHashtable
    if ($evidence.commit -cne $commit -or $evidence.status -cne 'validated' -or
        $evidence.unexpectedFailures.Count -ne 0 -or $evidence.baselineCommit -cne $PgrBaseline) {
        throw 'Run Test-Pgr49.ps1 successfully on this commit before building a distribution'
    }
    $sdk = (Invoke-PgrNative dotnet @('--version') $tree $log).Stdout
    if ($sdk -notmatch '^8\.') { throw "Expected the .NET 8 SDK, found $sdk" }
    Invoke-PgrNative rustc @('-vV') $tree $log | Out-Null
    if (!$MsBuild) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
        $MsBuild = (Invoke-PgrNative $vswhere @('-latest','-products','*','-requires','Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-find','MSBuild\**\Bin\amd64\MSBuild.exe') $tree $log).Stdout
    }
    if (!(Test-Path -LiteralPath $MsBuild -PathType Leaf)) { throw 'MSBuild x64 with VC++ Build Tools is required' }
    $label = "InfiniteLoop-$Version-$($commit.Substring(0, 12))-win-x64"
    $final = Join-Path $output $label
    if ((Test-Path -LiteralPath $final) -or (Test-Path -LiteralPath "$final.zip")) { throw "$label has already been built" }
    $scratch = [IO.Directory]::CreateDirectory((Join-Path $output (".build-$label-" + [guid]::NewGuid().ToString('N')))).FullName
    $stage = [IO.Directory]::CreateDirectory((Join-Path $scratch $label)).FullName
    Write-Host "Staging $label in $scratch"

    $oldCommit = $env:ASCNET_RELEASE_COMMIT
    $oldTargetDirectory = $env:CARGO_TARGET_DIR
    $targetDirectory = Join-Path $output 'cargo-target'
    try {
        $env:ASCNET_RELEASE_COMMIT = $commit
        $env:CARGO_TARGET_DIR = $targetDirectory
        Write-Host 'Building and testing the Windows launcher'
        Invoke-PgrNative cargo @('test','--manifest-path','AscNet.Launcher/Cargo.toml','--locked','--target',$PgrTarget,'-j','1') $tree (Join-Path $output "launcher-tests-$Version.log") | Out-Null
        Invoke-PgrNative cargo @('build','--manifest-path','AscNet.Launcher/Cargo.toml','--locked','--release','--target',$PgrTarget,'-j','1') $tree (Join-Path $output "launcher-build-$Version.log") | Out-Null
        Write-Host 'Building the native client patch'
        Invoke-PgrNative cargo @('build','--manifest-path','AscNet.Patch/Cargo.toml','--locked','--release','--target',$PgrTarget,'-j','1') $tree (Join-Path $output "patch-build-$Version.log") | Out-Null
    } finally {
        $env:ASCNET_RELEASE_COMMIT = $oldCommit
        $env:CARGO_TARGET_DIR = $oldTargetDirectory
    }
    $native = Join-Path $targetDirectory "$PgrTarget/release"
    Copy-Item -LiteralPath (Join-Path $native 'ascnet-launcher.exe') -Destination (Join-Path $stage 'AscNetLauncher.exe')
    $patch = [IO.Directory]::CreateDirectory((Join-Path $stage 'patch')).FullName
    Copy-Item -LiteralPath (Join-Path $native 'lucia.dll') -Destination $patch
    Copy-Item -LiteralPath (Join-Path $native 'krsdk.dll') -Destination (Join-Path $patch 'KRSDK.dll')
    $shim = Join-Path $scratch 'shim'
    Invoke-PgrNative $MsBuild @('AscNet.Patch/VersionShim/src/VersionShim.vcxproj','/p:Configuration=Release','/p:Platform=x64',
        "/p:OutDir=$shim/", "/p:IntDir=$shim/obj/", '/nologo') $tree (Join-Path $output "version-shim-$Version.log") | Out-Null
    Copy-Item -LiteralPath (Join-Path $shim 'VersionShim.dll') -Destination (Join-Path $patch 'version.dll')
    [IO.File]::WriteAllText((Join-Path $patch 'libraries.txt'), "*PGR.exe`nlucia.dll`n")
    foreach ($asset in @('launcher.json','supported-client.json')) {
        Copy-Item -LiteralPath (Join-Path $tree "AscNet.Launcher/$asset") -Destination $stage
    }
    Copy-Item -LiteralPath (Join-Path $stage 'supported-client.json') -Destination $patch
    Copy-Item -LiteralPath (Join-Path $tree 'Mods') -Destination $stage -Recurse

    Write-Host 'Publishing the matching x64 server'
    Invoke-PgrNative dotnet @('publish','AscNet/AscNet.csproj','-c','Release','-r','win-x64','--self-contained','false',
        '-o',(Join-Path $stage 'server'),"/p:InformationalVersion=1.0.0+$commit",'/p:IncludeSourceRevisionInInformationalVersion=false') $tree (Join-Path $output "server-publish-$Version.log") | Out-Null
    foreach ($asset in @('background.bmp','background.mp4','background.wav')) {
        Copy-Item -LiteralPath (Join-Path $MediaDirectory $asset) -Destination $stage
    }
    Copy-Item -LiteralPath $verificationPath -Destination (Join-Path $stage 'verification.json')
    foreach ($script in @('Common.ps1','Deployment.ps1','Deploy-Pgr49Release.ps1','Rollback-Pgr49Release.ps1','Start-Pgr49.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $script) -Destination $stage
    }
    if ((Invoke-PgrGit $tree $log @('status','--porcelain')).Stdout -or (Invoke-PgrGit $tree $log @('rev-parse','HEAD')).Stdout -cne $commit) {
        throw 'Source changed during the release build'
    }
    $manifest = [ordered]@{
        schemaVersion = 1; repository = $PgrFork; branch = $PgrBranch; commit = $commit
        version = $Version; dotnetSdk = $sdk; files = Get-PgrFileHashes $stage
    }
    Write-PgrJson (Join-Path $stage 'release.json') $manifest
    Assert-PgrRelease $stage | Out-Null
    Invoke-PgrNative (Join-Path $stage 'AscNetLauncher.exe') @('--verify-release') $stage $log | Out-Null
    $zipStage = Join-Path $scratch "$label.zip"
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipStage, [IO.Compression.CompressionLevel]::Optimal, $false)
    $zipHash = (Get-FileHash -LiteralPath $zipStage -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.Directory]::Move($stage, $final)
    [IO.File]::Move($zipStage, "$final.zip")
    [IO.File]::WriteAllText("$final.zip.sha256", "$zipHash  $label.zip`n")
    Write-Host "Built and verified $final.zip"
    $final
} catch {
    Write-PgrFailure $_ $log
    throw
}
