#requires -Version 7.0
<#
.SYNOPSIS
Capture a machine profile or run a bounded 1440p benchmark with isolated settings.
.DESCRIPTION
Use -ProfileOnly without a game launch. A run requires an explicit save-copy
directory, and terminates its process tree at DurationSeconds. Logs and receipts
stay outside all repositories. No affinity, page-file or driver settings change.
#>
[CmdletBinding()]
param(
    [switch]$ProfileOnly,
    [string]$GameExe,
    [string]$VictoryExe = (Join-Path $PSScriptRoot '..\target\release\victory.exe'),
    [string]$OutputRoot = (Join-Path $env:LOCALAPPDATA 'VIctory\benchmarks'),
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'VIctory\cache-pareto'),
    [string]$DataDir,
    [ValidateRange(1, 3600)][int]$DurationSeconds = 300,
    [ValidateRange(100, 10000)][int]$SampleMilliseconds = 1000,
    [ValidateRange(0, 1048576)][int]$MinimumPhysicalMiB = 512,
    [ValidateRange(0, 1048576)][int]$MinimumCommitMiB = 256,
    [ValidateRange(1, 60)][int]$MemoryPressureSeconds = 5,
    [ValidateSet('cold', 'warm', 'unspecified')][string]$CacheState = 'unspecified',
    [string]$Scene = 'unspecified',
    [hashtable]$Settings = @{}
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'benchmark-common.ps1')

$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$OutputRoot = Resolve-BenchmarkDataPath $OutputRoot
if (-not $ProfileOnly) {
    if (-not $GameExe -or -not (Test-Path -LiteralPath $GameExe -PathType Leaf)) { throw 'Provide -GameExe pointing to your game executable.' }
    if (-not (Test-Path -LiteralPath $VictoryExe -PathType Leaf)) { throw 'Build victory first, or provide -VictoryExe.' }
    if (-not $DataDir -or -not (Test-Path -LiteralPath $DataDir -PathType Container)) { throw 'Provide -DataDir pointing to a dedicated copy of your saves.' }
    $GameExe = (Resolve-Path -LiteralPath $GameExe).Path
    $VictoryExe = (Resolve-Path -LiteralPath $VictoryExe).Path
    $CacheDir = Resolve-BenchmarkDataPath $CacheDir
    $DataDir = Resolve-BenchmarkDataPath $DataDir
}
foreach ($key in $Settings.Keys) {
    if ($key -notmatch '^VICTORY_[A-Z0-9_]+$' -or $key -match '(_DIR$|^VICTORY_CONFIG$)') { throw "Unsupported setting name: $key" }
}
Initialize-BenchmarkNative
$runDir = Join-Path $OutputRoot ((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$cpuSets = @([VictoryBenchmark.Native]::CpuSets())
$gpu = @()
$nvidia = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidia) {
    $gpuLines = @(& $nvidia.Source --query-gpu=name,driver_version,memory.total --format=csv,noheader,nounits 2>$null)
    if ($LASTEXITCODE -eq 0) { $gpu = @($gpuLines | ConvertFrom-Csv -Header Name,Driver,MemoryMiB) }
}
$commit = $null
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitOutput = & git -C $repo rev-parse HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { $commit = "$gitOutput".Trim() }
}
$processorName = $env:PROCESSOR_IDENTIFIER
try {
    $processorName = (Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name ProcessorNameString).ProcessorNameString.Trim()
} catch { }
$profile = [ordered]@{
    SchemaVersion = 1
    TimestampUtc = [DateTime]::UtcNow.ToString('o')
    OS = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    Processor = $processorName
    ProcessorIdentifier = $env:PROCESSOR_IDENTIFIER
    LogicalProcessors = [Environment]::ProcessorCount
    PhysicalCores = if ($cpuSets.Count) { @($cpuSets | Group-Object Group,Core).Count } else { $null }
    CacheDomains = if ($cpuSets.Count) { @($cpuSets | Group-Object Group,Cache).Count } else { $null }
    CpuSets = $cpuSets
    Memory = Get-BenchmarkMemory
    GPU = $gpu
    SourceCommit = $commit
    SourceDirty = $null
}
if ($commit) {
    $dirty = @(& git -C $repo status --porcelain 2>$null)
    if ($LASTEXITCODE -eq 0) { $profile.SourceDirty = $dirty.Count -ne 0 }
}
$profile | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'machine.json') -Encoding utf8
if ($ProfileOnly) { Write-Output $runDir; return }

# Mirrors the current main launcher's rendering defaults. Child-only environment
# prevents inherited experiments and preserves the calling terminal's settings.
$effective = @{
    VICTORY_OUTPUT='2560x1440'; VICTORY_RENDER_SCALE='1.0'
    VICTORY_TEXTURE_NO_WAIT='1'; VICTORY_RELAY='2'; VICTORY_WIDE_BACK='1'
    VICTORY_CARD_REHASH_RUNS='1'; VICTORY_JOIN_COPIES='1'; VICTORY_INDIRECT_WINDOW='1'
    VICTORY_RELAY_COPY='1'; VICTORY_CARD_STEPS='2'; VICTORY_INDIRECT_BATCH='2'
    VICTORY_MAP_THREADS='1'; VICTORY_CARD_AWAKE='1'; VICTORY_SHOW_AFTER='1'
    VICTORY_AMBIENT_AIR='1.5'; VICTORY_AMBIENT='constant:0.8'; VICTORY_TEXTURE_GUARD='0'
    VICTORY_THIN='0'; VICTORY_JOIN_PARTS='0'; VICTORY_PORT_CONSTANTS='1'; VICTORY_PORT_CBV='1'
    VICTORY_UPLOAD_AHEAD='1'; VICTORY_LEVELS_ON_DEMAND='1'; VICTORY_CARD_BUFFERS_MIN_KB='64'
    VICTORY_LOG='info'; VICTORY_TIMER_LOG='1'; VICTORY_MEMORY_LOG='1'
}
foreach ($key in $Settings.Keys) { $effective[$key] = [string]$Settings[$key] }
$effective.VICTORY_GAME_DIR = Split-Path -Parent $GameExe
$effective.VICTORY_CACHE_DIR = $CacheDir
$effective.VICTORY_DATA_DIR = $DataDir
$start = [Diagnostics.ProcessStartInfo]::new($VictoryExe)
$start.WorkingDirectory = $runDir
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($key in @($start.Environment.Keys)) {
    if ($key -like 'VICTORY_*' -or $key -eq 'RUST_LOG') { [void]$start.Environment.Remove($key) }
}
foreach ($key in $effective.Keys) { $start.Environment[$key] = $effective[$key] }
foreach ($arg in @('run', $GameExe, '--console', 'series-x', '--execute')) { $start.ArgumentList.Add($arg) }
$receipt = [ordered]@{
    SchemaVersion=1; StartedUtc=[DateTime]::UtcNow.ToString('o'); Scene=$Scene; CacheState=$CacheState
    VictoryExe=$VictoryExe; ExecutableSHA256=(Get-FileHash -LiteralPath $VictoryExe -Algorithm SHA256).Hash
    SourceCommit=$commit; SourceDirty=$profile.SourceDirty
    BinaryMatchesSource='unverified'; Arguments=@($start.ArgumentList); Settings=$effective
    DurationSeconds=$DurationSeconds; SampleMilliseconds=$SampleMilliseconds
    Status='starting'; PID=$null; ExitCode=$null; EndReason=$null; Error=$null
    MemoryGuard=@{
        Enabled=($MinimumPhysicalMiB -gt 0 -or $MinimumCommitMiB -gt 0)
        MinimumPhysicalMiB=$MinimumPhysicalMiB; MinimumCommitMiB=$MinimumCommitMiB
        SustainedSeconds=$MemoryPressureSeconds; Trigger=$null
    }
    FrameTimes='Runtime logs only; process samples are not per-present frame timings.'
}
$receiptFile = Join-Path $runDir 'run.json'
$receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptFile -Encoding utf8
$process = [Diagnostics.Process]::new()
$process.StartInfo = $start
$stdout = $null; $stderr = $null; $samples = $null
$outTask = $null; $errTask = $null
try {
    if (-not $process.Start()) { throw 'Could not start the runtime.' }
    $receipt.PID = $process.Id
    $receipt.Status = 'running'
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptFile -Encoding utf8
    $stdout = [IO.FileStream]::new((Join-Path $runDir 'stdout.log'), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1, $true)
    $stderr = [IO.FileStream]::new((Join-Path $runDir 'stderr.log'), [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 1, $true)
    $outTask = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
    $errTask = $process.StandardError.BaseStream.CopyToAsync($stderr)
    $samples = [IO.StreamWriter]::new((Join-Path $runDir 'process.csv'))
    $samples.AutoFlush = $true
    $samples.WriteLine('elapsed_ms,private_bytes,working_set_bytes,cpu_seconds,system_commit_bytes,system_commit_limit_bytes,available_physical_bytes')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $pressureSince = $null
    while (-not $process.HasExited) {
        try {
            $process.Refresh()
            $privateBytes = $process.PrivateMemorySize64
            $workingBytes = $process.WorkingSet64
            $cpuSeconds = $process.TotalProcessorTime.TotalSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
        } catch {
            if ($process.HasExited) { break }
            throw
        }
        $memory = Get-BenchmarkMemory
        $samples.WriteLine([string]::Join(',', @(
            $clock.ElapsedMilliseconds, $privateBytes, $workingBytes, $cpuSeconds,
            $memory.CommitTotalBytes, $memory.CommitLimitBytes, $memory.PhysicalAvailableBytes)))
        $lowPhysical = $MinimumPhysicalMiB -gt 0 -and $memory.PhysicalAvailableBytes -lt ([long]$MinimumPhysicalMiB * 1MB)
        $lowCommit = $MinimumCommitMiB -gt 0 -and $memory.CommitAvailableBytes -lt ([long]$MinimumCommitMiB * 1MB)
        if ($lowPhysical -or $lowCommit) {
            if ($null -eq $pressureSince) { $pressureSince = $clock.ElapsedMilliseconds }
            if ($clock.ElapsedMilliseconds - $pressureSince -ge $MemoryPressureSeconds * 1000) {
                $receipt.EndReason = 'memory pressure'
                $receipt.MemoryGuard.Trigger = @{
                    ElapsedMilliseconds=$clock.ElapsedMilliseconds
                    PhysicalAvailableBytes=$memory.PhysicalAvailableBytes
                    CommitAvailableBytes=$memory.CommitAvailableBytes
                    LowPhysical=$lowPhysical; LowCommit=$lowCommit
                }
                $process.Kill($true)
                break
            }
        } else { $pressureSince = $null }
        if ($clock.Elapsed.TotalSeconds -ge $DurationSeconds) {
            $receipt.EndReason = 'duration limit'
            $process.Kill($true)
            break
        }
        [void]$process.WaitForExit($SampleMilliseconds)
    }
    $process.WaitForExit()
    [void]$outTask.GetAwaiter().GetResult()
    [void]$errTask.GetAwaiter().GetResult()
    $receipt.ExitCode = $process.ExitCode
    if (-not $receipt.EndReason) { $receipt.EndReason = 'process exited' }
    $receipt.Status = if ($receipt.EndReason -eq 'memory pressure') { 'stopped for memory pressure' } elseif ($receipt.EndReason -eq 'duration limit') { 'timed run completed' } elseif ($process.ExitCode -eq 0) { 'completed' } else { 'failed' }
} catch {
    $receipt.Status = 'failed'
    $receipt.Error = $_.Exception.Message
    throw
} finally {
    if ($receipt.PID -and -not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
    # Join stream pumps before closing their files, including on a sampling error.
    foreach ($task in @($outTask, $errTask)) { if ($null -ne $task) { try { [void]$task.GetAwaiter().GetResult() } catch {} } }
    foreach ($stream in @($samples, $stdout, $stderr)) { if ($null -ne $stream) { $stream.Dispose() } }
    $receipt['FinishedUtc'] = [DateTime]::UtcNow.ToString('o')
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptFile -Encoding utf8
    $process.Dispose()
    Write-Output $runDir
}
if ($receipt.Status -eq 'failed') { throw "Runtime exited with code $($receipt.ExitCode); see $runDir" }
