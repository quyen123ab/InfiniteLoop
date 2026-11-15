#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Sources','Test','Build')]
    [string]$Stage,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$HotfixZipPath,
    [string]$MongoExe,
    [string]$Verification,
    [string]$Version,
    [string]$MediaDirectory
)
. "$PSScriptRoot/Common.ps1"
$tree = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$output = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)).FullName
$log = Join-Path $output 'integration.log'
try {
    switch ($Stage) {
        'Sources' {
            $base = '716e3f239c0b67b36f9f2c1601e44258a3a45816'
            $gm = '36eeabfad36da25ac50e7313cfba8bd30a31f1ef'
            $refs = @(
                @{ Url = $PgrUpstream; Ref = 'refs/tags/1.0.24'; Commit = $base },
                @{ Url = $PgrFork; Ref = 'refs/heads/feat/live-gm-tools-9b3bf4b3e787'; Commit = $gm },
                @{ Url = $PgrFork; Ref = 'refs/heads/fix/pgr49-equipment-one-click'; Commit = $PgrBaseline }
            )
            foreach ($source in $refs) {
                Invoke-PgrGit $tree $log @('fetch','--no-tags',$source.Url,$source.Ref) | Out-Null
                Invoke-PgrGit $tree $log @('cat-file','-e',"$($source.Commit)^{commit}") | Out-Null
                $tip = (Invoke-PgrGit $tree $log @('rev-parse','FETCH_HEAD^{commit}')).Stdout
                if ($tip -cne $source.Commit) { throw "Expected $($source.Ref) at $($source.Commit), found $tip" }
                Write-Host "Verified $($source.Ref) at $tip"
            }
            if ($HotfixZipPath) {
                $hash = (Get-FileHash -LiteralPath $HotfixZipPath -Algorithm SHA256).Hash
                if ($hash -ine 'd6c24e0dfac8399c37a7a3700426d536a1272811a41c390dba2f93ce7fa65349') {
                    throw "Issue #67 source ZIP SHA-256 differs: $hash"
                }
                Add-Content -LiteralPath $log -Value "Verified Issue #67 source ZIP SHA-256 $hash"
            }
            foreach ($commit in @($base,$gm,$PgrBaseline,'3528a2e82b9be3d1ab0c0c43bfbc1756605016c3','5198e287')) {
                Invoke-PgrGit $tree $log @('merge-base','--is-ancestor',$commit,'HEAD') | Out-Null
            }
        }
        'Test' {
            if (!$MongoExe) { throw 'Specify -MongoExe for the disposable regression run' }
            & "$PSScriptRoot/Test-Pgr49.ps1" -MongoExe $MongoExe -OutputDirectory $output
        }
        'Build' {
            if (!$Version -or !$Verification -or !$MediaDirectory) { throw 'Specify -Version, -Verification and -MediaDirectory' }
            & "$PSScriptRoot/Build-Pgr49Release.ps1" -Version $Version -Verification $Verification -MediaDirectory $MediaDirectory -OutputDirectory $output
        }
    }
} catch {
    Write-PgrFailure $_ $log
    throw
}
