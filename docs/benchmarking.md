# Resource defaults and reproducible benchmarks

Offline compilation chooses job counts from physical cores, available logical
processors, RAM and available commit. This changes compilation concurrency only;
it does not change the game's renderer, affinity or memory-residency rules.

## Offline compilation

`translate`, `translate --warm`, `shaders`, and `warm` share the automatic policy.
It leaves an estimated 4 GiB reserve, budgets 1 GiB per shader worker or 2 GiB
per pipeline worker, and uses the smaller of available physical RAM and commit.
These are conservative initial estimates, not allocation guarantees.

On hosts with at most 32 GiB RAM, shader jobs cap at eight and pipeline jobs at
four. Larger hosts cap at sixteen and eight respectively. CPU and memory limits
may reduce these counts further. Missing memory information limits automatic
concurrency to two jobs; every automatic plan selects at least one worker.

An explicit positive `--jobs N` overrides these estimates. Zero is rejected.
The resolved count and detected resources are printed to stderr.

```powershell
.\target\release\victory.exe translate <shader-path> --jobs 4
.\target\release\victory.exe warm --used --jobs 4
```

Automatic pipeline warming also checks headroom before starting each child
process. It waits up to 30 seconds when less than the estimated reserve plus one
pipeline job is available, then returns an error. Previously completed entries
remain cached, and the deferred pipelines are not marked bad. Existing children
are allowed to complete. Explicit `--jobs` disables this pause as well. Memory
can change between checks and compiler usage varies, so this is backpressure,
not a hard process-memory limit.

## Machine profile

The benchmark scripts require PowerShell 7 and Windows. Profile-only mode does
not require a built runtime and never launches the game:

```powershell
pwsh -File scripts\benchmark.ps1 -ProfileOnly -OutputRoot D:\VIctoryBenchmarks
```

Each invocation creates a unique directory with `machine.json`. It records CPU
sets and cache domains, physical and committed system memory, Windows version,
NVIDIA driver/memory information when nvidia-smi is available, and source commit
and dirty state when Git is available. Failed CPU topology queries produce null
counts rather than claims that the machine has zero cores.

## Bounded game run

First build the checked-out source with the pinned toolchain:

```powershell
cargo build --locked --release -p victory -j 4
```

Make a dedicated copy of the saves you want to benchmark. A timed run terminates
the runtime process tree, so unsaved progress in that copy may be lost. Keep the
game, caches, save copies and benchmark output outside every source repository.
The script refuses paths inside repositories and paths crossing directory links.

```powershell
pwsh -File scripts\benchmark.ps1 `
  -GameExe D:\Games\MyDump\game_scarlett_master.exe `
  -DataDir D:\VIctoryBenchmarks\save-copy `
  -CacheDir D:\VIctoryBenchmarks\cache-copy `
  -OutputRoot D:\VIctoryBenchmarks\runs `
  -Scene indoor-prologue -CacheState warm -DurationSeconds 300
```

The baseline uses Series X, 2560x1440 output, native internal render scale,
the current main launcher's rendering settings, and the title's usual pacing.
Thin recording and submission joining stay disabled. Settings exist only in the
child environment; inherited VICTORY variables and RUST_LOG are cleared. The
calling terminal's environment remains intact. For a measured experiment:

```powershell
.\scripts\benchmark.ps1 -GameExe <exe> -DataDir <save-copy> `
  -Settings @{ VICTORY_PIPELINE_WORKERS = '4' }
```

The run directory contains `machine.json`, `run.json`, `process.csv`,
`stdout.log`, and `stderr.log`. Logs stream to disk. The receipt includes the
runtime executable SHA-256, exact arguments and settings, process ID, outcome
and exit code. Source commit and binary hash are recorded separately: an
arbitrary executable is not asserted to match the current checkout. Nonzero
runtime exits produce a failed receipt and a script error. Time-limited runs
are labeled explicitly rather than reported as natural successful exits.

`process.csv` samples process private bytes, working set and cumulative CPU time,
alongside system commit and available physical memory. It samples the initial
runtime process, not the aggregate of independently relaunched processes. GPU
information in `machine.json` is a hardware snapshot, not per-frame GPU timing.
Runtime timer logs are retained, but process samples are not present events and
must not be used to claim frame-time p95/p99 or 30 FPS. Per-present timing and
matched scene comparisons are the next measurement step.

`CacheState` and `Scene` label a run. They do not clear caches, copy saves or
automate a route. Match these conditions yourself and keep cold and warm runs
separate. Receipts can contain local paths and hardware information; review them
before sharing. Proprietary logs/captures belong outside Git.

## Validation

```powershell
cargo test --workspace --locked -j 4
cargo clippy -p victory-core --all-targets --locked -- -D warnings
pwsh -File scripts\tests\benchmark.tests.ps1 -WorkRoot D:\VIctoryBenchmarkTests
```

The PowerShell checks compile a small synthetic .NET Framework process with
Windows' csc.exe. They test profiling, repository-path rejection, child arguments
and environment isolation, normal/nonzero exits, log draining and duration
termination without reading or executing a real game.
