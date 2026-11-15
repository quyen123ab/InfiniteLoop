#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$MongoExe,
    [Parameter(Mandatory)][string]$OutputDirectory
)
. "$PSScriptRoot/Common.ps1"
$tree = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($output) | Out-Null
$run = [IO.Directory]::CreateDirectory((Join-Path $output ("regression-" + [guid]::NewGuid().ToString('N')))).FullName
$log = Join-Path $run 'run.log'
$mongo = $null

$focused = [ordered]@{
    '--live-gm-only' = 'ValidateLiveGmControl'
    '--live-gm-items-only' = 'ValidateLiveGmItems'
    '--guide-progression-only' = 'ValidateGuideProgression'
    '--equipment-one-click-shops-only' = 'ValidateEquipmentOneClickShops'
    '--equipment-one-click-upgrade-only' = 'ValidateEquipmentOneClickUpgrade'
    '--version49-memory-shop-only' = 'ValidateVersion49MemoryShop'
    '--inventory-equip-compat-only' = 'ValidateInventoryEquipCompatibility'
    '--shop-compat-only' = 'ValidateShopCompatibility'
    '--simulated-battlefield-compat-only' = 'ValidateSimulatedBattlefieldCompatibility'
    '--partner-quick-upgrade-only' = 'ValidatePartnerQuickUpgrade'
    '--partner-decompose-compat-only' = 'ValidatePartnerDecomposeCompatibilitySuite'
    '--partner-decompose-real-mongo-only' = $null
    '--partner-story-only' = 'ValidatePartnerStoryCompatibility'
    '--guild-compat-only' = $null
}

function Read-PgrSteps {
    param($Result)
    $steps = [ordered]@{}
    foreach ($line in ($Result.Stdout -split '\r?\n')) {
        if ($line -notmatch '^@@(PASS|FAIL) (\S+)(?: (.+))?$') { continue }
        if ($steps.Contains($Matches[2])) { throw "Duplicate harness step $($Matches[2])" }
        $steps.Add($Matches[2], @{ status = $Matches[1]; reason = $Matches[3] })
    }
    $failed = @($steps.Values | Where-Object { $_.status -eq 'FAIL' }).Count
    if ($steps.Count -eq 0 -or ($Result.ExitCode -eq 0) -eq ($failed -gt 0)) {
        throw 'The harness failed to report a consistent full run'
    }
    return $steps
}

function Build-PgrHarness {
    param([string]$Source, [string]$Name)
    $buildLog = Join-Path $run "$Name-build.log"
    Invoke-PgrNative dotnet @('build','AscNet.Test/AscNet.Test.csproj','-c','Release') $Source $buildLog | Out-Null
    $built = Join-Path $Source 'AscNet.Test/bin/Release/net8.0'
    # Live GM exercises a second server process and writes its config beside the test assembly.
    $testOutput = Join-Path $run "$Name-test-host"
    Copy-Item -LiteralPath $built -Destination $testOutput -Recurse
    Write-PgrJson (Join-Path $testOutput 'Configs/config.json') @{
        Database = @{ Host = '127.0.0.1'; Port = 27019; Name = "ascnet_manual_full_pgr49_$Name" }
    }
    return $testOutput
}

function Invoke-PgrGuildHarness {
    param([string]$HostDirectory, [string]$Log)
    $config = Join-Path $HostDirectory 'Configs/config.json'
    $bytes = [IO.File]::ReadAllBytes($config)
    try {
        Write-PgrJson $config @{ Database = @{ Host = '127.0.0.1'; Port = 27019; Name = 'ascnet_guild_verification' } }
        Invoke-PgrNative dotnet @('AscNet.Test.dll','--guild-compat-only') $HostDirectory $Log -AllowFailure
    } finally {
        [IO.File]::WriteAllBytes($config, $bytes)
    }
}

try {
    Write-Host "PGR 4.9 regression logs are in $run"
    $commit = (Invoke-PgrGit $tree $log @('rev-parse','HEAD')).Stdout
    if ((Invoke-PgrGit $tree $log @('status','--porcelain')).Stdout) { throw 'Commit source changes before running release validation' }
    $sdk = (Invoke-PgrNative dotnet @('--version') $tree $log).Stdout
    if ($sdk -notmatch '^8\.') { throw "Expected the .NET 8 SDK, found $sdk" }

    $runner = Get-Content -Raw -LiteralPath (Join-Path $tree 'AscNet.Test/Program.cs')
    foreach ($flag in @($focused.Keys) + '--keep-going') {
        if (!$runner.Contains('args.Contains("' + $flag + '")')) { throw "Missing harness selector $flag" }
    }
    $candidateHost = Build-PgrHarness $tree 'candidate'
    $baselineTree = Join-Path $run 'baseline-src'
    $exists = Invoke-PgrGit $tree $log @('cat-file','-e',"$PgrBaseline^{commit}") -AllowFailure
    if ($exists.ExitCode) { Invoke-PgrGit $tree $log @('fetch','--no-tags',$PgrFork,'refs/heads/fix/pgr49-equipment-one-click') | Out-Null }
    Invoke-PgrGit $tree $log @('worktree','add','--detach',$baselineTree,$PgrBaseline) | Out-Null
    Copy-Item -LiteralPath (Join-Path $tree 'global.json') -Destination $run
    $baselineHost = Build-PgrHarness $baselineTree 'baseline'

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 27019)
    $listener.ExclusiveAddressUse = $true
    try { $listener.Start() } finally { $listener.Stop() }
    $mongoExe = (Get-Item -LiteralPath $MongoExe).FullName
    $mongoPath = [IO.Directory]::CreateDirectory((Join-Path $run 'mongodb')).FullName
    $mongoLog = Join-Path $run 'mongod.log'
    $start = [Diagnostics.ProcessStartInfo]::new($mongoExe)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($arg in @('--bind_ip','127.0.0.1','--port','27019','--dbpath',$mongoPath,'--logpath',$mongoLog)) {
        $start.ArgumentList.Add($arg)
    }
    $mongo = [Diagnostics.Process]::Start($start)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    do {
        if ($mongo.HasExited) { throw "Disposable mongod exited $($mongo.ExitCode). See $mongoLog" }
        $ready = (Test-Path -LiteralPath $mongoLog) -and (Select-String -Quiet -LiteralPath $mongoLog -SimpleMatch 'Waiting for connections')
        if (!$ready) { Start-Sleep -Milliseconds 200 }
    } until ($ready -or [DateTimeOffset]::UtcNow -ge $deadline)
    if (!$ready -or $mongo.HasExited) { throw "Disposable MongoDB did not listen on port 27019. See $mongoLog" }

    # The harness owns its test config. Prevent inherited server settings from redirecting it.
    $oldConfigPath = $env:ASCNET_CONFIG_PATH
    Remove-Item Env:ASCNET_CONFIG_PATH -ErrorAction SilentlyContinue
    try {
        $focusResults = [ordered]@{}
        foreach ($flag in $focused.Keys) {
            if ($mongo.HasExited) { throw 'Disposable MongoDB stopped during the regression run' }
            Write-Host "Running $flag"
            $flagLog = Join-Path $run ($flag.Substring(2) + '.log')
            if ($flag -ne '--guild-compat-only') {
                $focusResults[$flag] = (Invoke-PgrNative dotnet @('AscNet.Test.dll',$flag) $candidateHost $flagLog -AllowFailure).ExitCode
                continue
            }
            $guildCandidate = Invoke-PgrGuildHarness $candidateHost $flagLog
            $focusResults[$flag] = $guildCandidate.ExitCode
            $guildBaseline = Invoke-PgrGuildHarness $baselineHost (Join-Path $run 'baseline-guild-compat-only.log')
        }
        $guildReproduction = $null
        if ($guildCandidate.ExitCode -ne 0 -and $guildCandidate.ExitCode -eq $guildBaseline.ExitCode) {
            $first = ($guildCandidate.Stderr -split '\r?\n')[0]
            $second = ($guildBaseline.Stderr -split '\r?\n')[0]
            if ($first -ceq 'System.IO.InvalidDataException: creation debits configured cost once' -and $second -ceq $first) {
                $guildReproduction = $first
            }
        }
        if ($mongo.HasExited) { throw 'Disposable MongoDB stopped during the regression run' }
        Write-Host 'Running the full candidate and PR #66 baseline suites'
        $candidate = Read-PgrSteps (Invoke-PgrNative dotnet @('AscNet.Test.dll','--keep-going') $candidateHost (Join-Path $run 'candidate-full.log') -AllowFailure)
        $baseline = Read-PgrSteps (Invoke-PgrNative dotnet @('AscNet.Test.dll','--keep-going') $baselineHost (Join-Path $run 'baseline-full.log') -AllowFailure)
    } finally {
        $env:ASCNET_CONFIG_PATH = $oldConfigPath
    }
    $unexpected = [Collections.Generic.List[string]]::new()
    $known = [ordered]@{}
    foreach ($flag in $focused.Keys) {
        if ($focusResults[$flag] -ne 0 -and !($flag -eq '--guild-compat-only' -and $guildReproduction)) {
            $unexpected.Add("$flag exited $($focusResults[$flag])")
        }
        $required = $focused[$flag]
        if ($required -and (!$candidate.Contains($required) -or $candidate[$required].status -ne 'PASS')) {
            $unexpected.Add("Required full-suite step did not pass: $required")
        }
    }
    foreach ($name in $baseline.Keys) {
        if (!$candidate.Contains($name)) { $unexpected.Add("Missing full-suite step: $name") }
    }
    foreach ($name in $candidate.Keys) {
        $step = $candidate[$name]
        if ($step.status -ne 'FAIL') { continue }
        if ($baseline.Contains($name) -and $baseline[$name].status -eq 'FAIL' -and
            $baseline[$name].reason -ceq $step.reason) {
            $known.Add($name, $step.reason)
        } else {
            $unexpected.Add("$name $($step.reason)")
        }
    }
    $report = [ordered]@{
        schemaVersion = 1; commit = $commit; baselineCommit = $PgrBaseline
        status = if ($unexpected.Count -eq 0) { 'validated' } else { 'failed' }
        focusedPassed = @($focusResults.Values | Where-Object { $_ -eq 0 }).Count
        focused = $focusResults
        guildBaselineReproduction = $guildReproduction
        candidatePassed = @($candidate.Values | Where-Object { $_.status -eq 'PASS' }).Count
        candidateFailed = @($candidate.Values | Where-Object { $_.status -eq 'FAIL' }).Count
        baselinePassed = @($baseline.Values | Where-Object { $_.status -eq 'PASS' }).Count
        baselineFailed = @($baseline.Values | Where-Object { $_.status -eq 'FAIL' }).Count
        baselineReproductions = $known
        unexpectedFailures = @($unexpected)
    }
    $reportPath = Join-Path $run 'verification.json'
    Write-PgrJson $reportPath $report
    if ($unexpected.Count) { throw "Unexpected regression results. See $reportPath" }
    Write-Host ("Candidate {0} passed, {1} baseline failures. Baseline {2} passed, {3} failed." -f
        $report.candidatePassed, $report.candidateFailed, $report.baselinePassed, $report.baselineFailed)
    $reportPath
} catch {
    Write-PgrFailure $_ $log
    throw
} finally {
    if ($null -ne $mongo) {
        if (!$mongo.HasExited) { $mongo.Kill(); $mongo.WaitForExit() }
        $mongo.Dispose()
    }
}
