//! Offline compilation limits, shared by the CLI commands.
use anyhow::Result;
use victory_core::resources::{Compilation, JobPlan, Resources, compilation_jobs};

pub fn plan(kind: Compilation, asked: Option<usize>) -> Result<JobPlan> {
    let resources = Resources::detect();
    let plan = compilation_jobs(resources, kind, asked).map_err(anyhow::Error::msg)?;
    eprintln!(
        "offline compilation {kind:?}: {} jobs (automatic: {}), resources: {resources:?}",
        plan.jobs, plan.automatic
    );
    Ok(plan)
}

/// Only automatic warm-up pauses; --jobs explicitly opts out. Completed cache
/// entries survive a timeout, and no unstarted pipeline is marked as bad.
#[cfg(windows)]
pub fn wait_for_pipeline_memory(automatic: bool) -> Result<()> {
    if !automatic {
        return Ok(());
    }
    let began = std::time::Instant::now();
    let mut warned = false;
    loop {
        let resources = Resources::detect();
        if Compilation::Pipeline.can_start(resources) {
            return Ok(());
        }
        if !warned {
            eprintln!(
                "pipeline warm-up paused for memory headroom; waiting up to 30 seconds: {resources:?}"
            );
            warned = true;
        }
        anyhow::ensure!(
            began.elapsed().as_secs() < 30,
            "pipeline warm-up still lacks memory headroom after 30 seconds; completed entries are cached; free memory and retry, or explicitly set --jobs"
        );
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
}
