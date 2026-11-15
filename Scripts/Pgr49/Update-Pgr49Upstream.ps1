#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$UpstreamCommit,
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')][string]$UpstreamTag,
    [Parameter(Mandatory)][string]$Worktree,
    [Parameter(Mandatory)][string]$MongoExe,
    [Parameter(Mandatory)][string]$MediaDirectory,
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+-pgr49\.\d+$')][string]$Version,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [switch]$Resume
)
. "$PSScriptRoot/Common.ps1"
$tree = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$candidate = [IO.Path]::GetFullPath($Worktree)
$output = [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($OutputDirectory)).FullName
$log = Join-Path $output "upstream-$Version.log"
$updateBranch = "update/pgr49-$Version"
try {
    if (!$Resume) {
        if (Test-Path -LiteralPath $candidate) { throw 'Choose a new candidate worktree path, or use -Resume' }
        Invoke-PgrGit $tree $log @('fetch','--no-tags',$PgrFork,"refs/heads/${PgrBranch}:refs/remotes/pgr49/$PgrBranch") | Out-Null
        $custom = "refs/remotes/pgr49/$PgrBranch"
        $tag = "refs/tags/$UpstreamTag"
        Invoke-PgrGit $tree $log @('fetch','--no-tags',$PgrUpstream,$tag) | Out-Null
        $observed = (Invoke-PgrGit $tree $log @('rev-parse','FETCH_HEAD^{commit}')).Stdout
        if ($observed -cne $UpstreamCommit) { throw "Upstream $tag resolves to $observed, expected $UpstreamCommit" }
        Invoke-PgrGit $tree $log @('worktree','add','-b',$updateBranch,$candidate,$custom) | Out-Null
        if ((Invoke-PgrGit $candidate $log @('merge-base','--is-ancestor',$UpstreamCommit,'HEAD') -AllowFailure).ExitCode -eq 0) {
            throw 'The selected upstream release is already present on the canonical branch'
        }
        $merge = Invoke-PgrGit $candidate $log @('merge','--no-ff','-m',"Merge upstream $UpstreamTag",$UpstreamCommit) -AllowFailure
        if ($merge.ExitCode) {
            $unmerged = (Invoke-PgrGit $candidate $log @('diff','--name-only','--diff-filter=U')).Stdout
            throw "Merge exited $($merge.ExitCode) in $candidate. Unmerged paths: $unmerged. Review $log, resolve and commit, then use -Resume."
        }
    }
    $activeBranch = (Invoke-PgrGit $candidate $log @('branch','--show-current')).Stdout
    if ($activeBranch -cne $updateBranch) { throw "Expected candidate branch $updateBranch" }
    Invoke-PgrGit $candidate $log @('merge-base','--is-ancestor',"refs/remotes/pgr49/$PgrBranch",'HEAD') | Out-Null
    Invoke-PgrGit $candidate $log @('merge-base','--is-ancestor',$UpstreamCommit,'HEAD') | Out-Null
    if ((Invoke-PgrGit $candidate $log @('status','--porcelain')).Stdout) { throw 'Resolve and commit changes before resuming' }
    $verification = & (Join-Path $candidate 'Scripts/Pgr49/Test-Pgr49.ps1') -MongoExe $MongoExe -OutputDirectory $output
    & (Join-Path $candidate 'Scripts/Pgr49/Build-Pgr49Release.ps1') -Verification $verification -Version $Version -MediaDirectory $MediaDirectory -OutputDirectory $output
    Write-Host "Validated candidate $updateBranch. Review before fast-forwarding $PgrBranch on the fork."
} catch {
    Write-PgrFailure $_ $log
    throw
}
