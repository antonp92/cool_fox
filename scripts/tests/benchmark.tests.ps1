#requires -Version 7.0
param([Parameter(Mandatory)][string]$WorkRoot)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$benchmark = Join-Path $repo 'scripts\benchmark.ps1'
. (Join-Path $repo 'scripts\benchmark-common.ps1')
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$WorkRoot = Resolve-BenchmarkDataPath $WorkRoot
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$profileDir = & $benchmark -ProfileOnly -OutputRoot (Join-Path $WorkRoot 'profiles')
$profile = Get-Content -LiteralPath (Join-Path $profileDir 'machine.json') -Raw | ConvertFrom-Json
Assert ($profile.LogicalProcessors -gt 0) 'Missing CPU profile'
Assert ($profile.Memory.CommitLimitBytes -gt 0) 'Missing memory profile'
try { Resolve-BenchmarkDataPath (Join-Path $repo 'not-created\data') | Out-Null; throw 'Repository path was accepted' }
catch { if ($_.Exception.Message -eq 'Repository path was accepted') { throw } }
try { & $benchmark -ProfileOnly -OutputRoot $repo | Out-Null; throw 'Repository output was accepted' }
catch { if ($_.Exception.Message -eq 'Repository output was accepted') { throw } }

$source = @'
using System;
using System.IO;
using System.Threading;
public class Fixture {
    public static int Main(string[] args) {
        if (args.Length != 5 || args[0] != "run" || args[2] != "--console" || args[3] != "series-x" || args[4] != "--execute") return 20;
        if (Environment.GetEnvironmentVariable("VICTORY_OUTPUT") != "2560x1440") return 21;
        if (Environment.GetEnvironmentVariable("VICTORY_THIN") != "0") return 22;
        if (Environment.GetEnvironmentVariable("VICTORY_PIPELINE_WORKERS") != "3") return 23;
        if (Environment.GetEnvironmentVariable("VICTORY_BVH_BUILDER") != null) return 24;
        Console.WriteLine("fixture stdout");
        Console.Error.WriteLine("fixture stderr");
        Thread.Sleep(100);
        using (var readable = new FileStream("stdout.log", FileMode.Open, FileAccess.Read, FileShare.ReadWrite)) {
            Console.WriteLine("live log readable");
        }
        if (Path.GetFileName(args[1]).Contains("timeout") || Path.GetFileName(args[1]).Contains("pressure")) Thread.Sleep(10000);
        return Path.GetFileName(args[1]).Contains("failure") ? 7 : 0;
    }
}
'@
$sourcePath = Join-Path $WorkRoot 'Fixture.cs'
$fixture = Join-Path $WorkRoot 'fixture.exe'
Set-Content -LiteralPath $sourcePath -Value $source
& (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo "/out:$fixture" $sourcePath
if ($LASTEXITCODE) { throw 'Fixture compile failed' }
$saveCopy = Join-Path $WorkRoot 'save copy'
New-Item -ItemType Directory -Path $saveCopy -Force | Out-Null
$oldValue = $env:VICTORY_BVH_BUILDER
$env:VICTORY_BVH_BUILDER = 'inherited-experiment'
try {
    $invalidRuntime = Join-Path $WorkRoot 'not-an-executable.txt'
    Set-Content -LiteralPath $invalidRuntime -Value 'Not a program.'
    $inputFile = Join-Path $WorkRoot 'start failure input.exe'
    Set-Content -LiteralPath $inputFile -Value 'Synthetic input.'
    $invalidOutput = Join-Path $WorkRoot 'start-failure'
    $startFailed = $false
    try {
        & $benchmark -VictoryExe $invalidRuntime -GameExe $inputFile -DataDir $saveCopy -CacheDir (Join-Path $WorkRoot 'cache') -OutputRoot $invalidOutput | Out-Null
    } catch { $startFailed = $true }
    Assert $startFailed 'Invalid runtime launch succeeded'
    $failedRun = Get-ChildItem -LiteralPath $invalidOutput -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $failedReceipt = Get-Content -LiteralPath (Join-Path $failedRun.FullName 'run.json') -Raw | ConvertFrom-Json
    Assert ($failedReceipt.Status -eq 'failed' -and $failedReceipt.Error) 'Launch failure receipt was lost'
    Write-Output 'start-failure fixture passed'
    foreach ($case in @('success', 'failure', 'timeout', 'pressure', 'commit-pressure', 'pressure-disabled')) {
        $game = Join-Path $WorkRoot "$case game.exe"
        Set-Content -LiteralPath $game -Value 'Synthetic test input; not an executable.'
        $output = Join-Path $WorkRoot $case
        $caught = $false
        $guard = @{}
        if ($case -eq 'pressure') {
            # An impossible physical floor triggers the real guard without
            # consuming memory or depending on current host pressure.
            $guard = @{MinimumPhysicalMiB=1048576; MinimumCommitMiB=0; MemoryPressureSeconds=1; DurationSeconds=5}
        } elseif ($case -eq 'commit-pressure') {
            $guard = @{MinimumPhysicalMiB=0; MinimumCommitMiB=1048576; MemoryPressureSeconds=1; DurationSeconds=5}
        } elseif ($case -eq 'pressure-disabled') {
            $guard = @{MinimumPhysicalMiB=0; MinimumCommitMiB=0; DurationSeconds=1}
        } else { $guard = @{DurationSeconds=1} }
        try {
            $result = @(& $benchmark -VictoryExe $fixture -GameExe $game -DataDir $saveCopy -CacheDir (Join-Path $WorkRoot 'cache') -OutputRoot $output -SampleMilliseconds 100 -Settings @{VICTORY_PIPELINE_WORKERS='3'} @guard)
            Assert ($result.Count -eq 1 -and $result[0] -is [string]) 'Runner emitted values other than its result directory'
        } catch { $caught = $true }
        $run = Get-ChildItem -LiteralPath $output -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $receipt = Get-Content -LiteralPath (Join-Path $run.FullName 'run.json') -Raw | ConvertFrom-Json
        if ($case -eq 'success') {
            Assert (-not $caught -and $receipt.ExitCode -eq 0 -and $receipt.Status -eq 'completed') 'Successful run failed'
        } elseif ($case -eq 'failure') {
            Assert ($caught -and $receipt.ExitCode -eq 7 -and $receipt.Status -eq 'failed') 'Failed run was not recorded'
        } elseif ($case -in @('pressure', 'commit-pressure')) {
            Assert (-not $caught -and $receipt.Status -eq 'stopped for memory pressure' -and $receipt.EndReason -eq 'memory pressure') 'Memory stop was not recorded'
            Assert ($receipt.MemoryGuard.Enabled) 'Memory guard was disabled'
            if ($case -eq 'pressure') { Assert ($receipt.MemoryGuard.Trigger.LowPhysical -and -not $receipt.MemoryGuard.Trigger.LowCommit) 'Wrong physical trigger' }
            else { Assert ($receipt.MemoryGuard.Trigger.LowCommit -and -not $receipt.MemoryGuard.Trigger.LowPhysical) 'Wrong commit trigger' }
            Assert ($receipt.MemoryGuard.Trigger.ElapsedMilliseconds -ge 1000) 'Guard did not wait for sustained pressure'
        } else {
            Assert (-not $caught -and $receipt.EndReason -eq 'duration limit') 'Bounded run failed'
            if ($case -eq 'pressure-disabled') { Assert (-not $receipt.MemoryGuard.Enabled) 'Zero floors did not disable the guard' }
        }
        Assert ((Get-Content -LiteralPath (Join-Path $run.FullName 'stdout.log') -Raw) -match 'fixture stdout') 'stdout not drained'
        Assert ((Get-Content -LiteralPath (Join-Path $run.FullName 'stderr.log') -Raw) -match 'fixture stderr') 'stderr not drained'
        Assert ($env:VICTORY_BVH_BUILDER -eq 'inherited-experiment') 'Caller environment was changed'
        Write-Output "$case fixture passed"
    }
} finally { $env:VICTORY_BVH_BUILDER = $oldValue }
Write-Output 'Profile, path guard, environment isolation, exit handling, log draining, timeout, and memory-stop checks passed.'
