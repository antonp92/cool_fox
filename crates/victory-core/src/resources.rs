//! Resource-aware defaults for offline compilation. Estimates bound concurrency,
//! not the game's memory usage; explicit job counts remain an escape hatch.

#[cfg(windows)]
use std::collections::BTreeSet;

const GIB: u64 = 1 << 30;
pub const COMPILATION_RESERVE: u64 = 4 * GIB;

#[derive(Clone, Copy, Debug, Default)]
pub struct Resources {
    pub logical_processors: usize,
    pub physical_cores: Option<usize>,
    pub cache_domains: Option<usize>,
    pub total_physical: Option<u64>,
    pub available_physical: Option<u64>,
    /// Available process commit, which may be lower than system-wide headroom.
    pub available_commit: Option<u64>,
}

impl Resources {
    pub fn detect() -> Self {
        let result = Self {
            logical_processors: std::thread::available_parallelism().map_or(1, |n| n.get()),
            ..Self::default()
        };
        #[cfg(windows)]
        let result = {
            let mut detected = result;
            detected.sample_windows();
            detected
        };
        result
    }

    pub fn headroom(self) -> Option<u64> {
        match (self.available_physical, self.available_commit) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }

    #[cfg(windows)]
    fn sample_windows(&mut self) {
        use windows_sys::Win32::System::SystemInformation::{
            GetSystemCpuSetInformation, GlobalMemoryStatusEx, MEMORYSTATUSEX,
            SYSTEM_CPU_SET_INFORMATION,
        };
        use windows_sys::Win32::System::Threading::GetCurrentProcess;

        // SAFETY: a correctly sized output structure filled by the OS.
        let mut memory: MEMORYSTATUSEX = unsafe { std::mem::zeroed() };
        memory.dwLength = size_of::<MEMORYSTATUSEX>() as u32;
        // SAFETY: memory is writable and its size was initialized above.
        if unsafe { GlobalMemoryStatusEx(&mut memory) } != 0 {
            self.total_physical = Some(memory.ullTotalPhys);
            self.available_physical = Some(memory.ullAvailPhys);
            self.available_commit = Some(memory.ullAvailPageFile);
        }
        let mut bytes = 0;
        // SAFETY: the size query uses no output buffer and a valid pseudo handle.
        unsafe {
            GetSystemCpuSetInformation(std::ptr::null_mut(), 0, &mut bytes, GetCurrentProcess(), 0)
        };
        let mut storage = vec![0u64; (bytes as usize).div_ceil(8).max(1)];
        let capacity = storage.len() * 8;
        // SAFETY: storage is aligned and holds at least bytes bytes.
        let ok = unsafe {
            GetSystemCpuSetInformation(
                storage.as_mut_ptr().cast(),
                bytes,
                &mut bytes,
                GetCurrentProcess(),
                0,
            )
        };
        if ok == 0 || bytes as usize > capacity {
            return;
        }
        let (mut cores, mut caches) = (BTreeSet::new(), BTreeSet::new());
        let mut at = 0;
        while at + size_of::<SYSTEM_CPU_SET_INFORMATION>() <= bytes as usize {
            // SAFETY: a full, aligned OS record is inside the buffer.
            let info = unsafe {
                &*storage
                    .as_ptr()
                    .cast::<u8>()
                    .add(at)
                    .cast::<SYSTEM_CPU_SET_INFORMATION>()
            };
            let size = info.Size as usize;
            if size < size_of::<SYSTEM_CPU_SET_INFORMATION>()
                || size > bytes as usize - at
                || !size.is_multiple_of(8)
            {
                break;
            }
            if info.Type == 0 {
                // SAFETY: Type 0 identifies a CPU set record.
                let set = unsafe { &info.Anonymous.CpuSet };
                cores.insert((set.Group, set.CoreIndex));
                caches.insert((set.Group, set.LastLevelCacheIndex));
            }
            at += size;
        }
        self.physical_cores = (!cores.is_empty()).then_some(cores.len());
        self.cache_domains = (!caches.is_empty()).then_some(caches.len());
    }
}

#[derive(Clone, Copy, Debug)]
pub enum Compilation {
    Shader,
    Pipeline,
}

impl Compilation {
    /// Conservative starting estimates; compiler memory varies by shader/driver.
    pub fn bytes_per_job(self) -> u64 {
        match self {
            Self::Shader => GIB,
            Self::Pipeline => 2 * GIB,
        }
    }

    pub fn can_start(self, resources: Resources) -> bool {
        resources
            .headroom()
            .is_none_or(|free| free >= COMPILATION_RESERVE + self.bytes_per_job())
    }
}

#[derive(Clone, Copy, Debug)]
pub struct JobPlan {
    pub jobs: usize,
    pub automatic: bool,
}

pub fn compilation_jobs(
    resources: Resources,
    kind: Compilation,
    asked: Option<usize>,
) -> Result<JobPlan, &'static str> {
    if let Some(jobs) = asked {
        return if jobs == 0 {
            Err("--jobs must be at least 1")
        } else {
            Ok(JobPlan {
                jobs,
                automatic: false,
            })
        };
    }
    let logical = resources.logical_processors.max(1);
    let physical = resources
        .physical_cores
        .unwrap_or(logical.div_ceil(2))
        .clamp(1, logical);
    let limited = resources
        .total_physical
        .is_none_or(|total| total <= 32 * GIB);
    let ceiling = match (kind, limited) {
        (Compilation::Shader, false) => 16,
        (Compilation::Shader, true) | (Compilation::Pipeline, false) => 8,
        (Compilation::Pipeline, true) => 4,
    };
    let memory = resources.headroom().map_or(2, |free| {
        (free.saturating_sub(COMPILATION_RESERVE) / kind.bytes_per_job()).min(usize::MAX as u64)
            as usize
    });
    Ok(JobPlan {
        jobs: physical.min(ceiling).min(memory.max(1)),
        automatic: true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pc(total: u64, physical: u64, commit: u64) -> Resources {
        Resources {
            logical_processors: 32,
            physical_cores: Some(16),
            total_physical: Some(total * GIB),
            available_physical: Some(physical * GIB),
            available_commit: Some(commit * GIB),
            ..Resources::default()
        }
    }

    #[cfg(windows)]
    #[test]
    fn windows_resource_queries_return_memory_and_cpu_topology() {
        let resources = Resources::detect();
        assert!(resources.logical_processors > 0);
        assert!(resources.physical_cores.is_some_and(|n| n > 0));
        assert!(resources.total_physical.is_some_and(|n| n > 0));
        assert!(resources.available_physical.is_some());
        assert!(resources.available_commit.is_some());
    }

    #[test]
    fn commit_and_physical_pressure_both_constrain_compilation() {
        for resources in [pc(32, 16, 10), pc(32, 10, 16)] {
            assert_eq!(
                compilation_jobs(resources, Compilation::Pipeline, None)
                    .unwrap()
                    .jobs,
                3
            );
            assert_eq!(
                compilation_jobs(resources, Compilation::Shader, None)
                    .unwrap()
                    .jobs,
                6
            );
        }
        assert_eq!(
            compilation_jobs(pc(32, 28, 40), Compilation::Pipeline, None)
                .unwrap()
                .jobs,
            4
        );
        assert_eq!(
            compilation_jobs(pc(32, 28, 40), Compilation::Shader, None)
                .unwrap()
                .jobs,
            8
        );
    }

    #[test]
    fn large_hosts_scale_without_using_every_smt_thread() {
        let mut resources = pc(64, 48, 80);
        assert_eq!(
            compilation_jobs(resources, Compilation::Shader, None)
                .unwrap()
                .jobs,
            16
        );
        assert_eq!(
            compilation_jobs(resources, Compilation::Pipeline, None)
                .unwrap()
                .jobs,
            8
        );
        resources.physical_cores = Some(4);
        assert_eq!(
            compilation_jobs(resources, Compilation::Shader, None)
                .unwrap()
                .jobs,
            4
        );
        resources.logical_processors = 2;
        assert_eq!(
            compilation_jobs(resources, Compilation::Shader, None)
                .unwrap()
                .jobs,
            2
        );
    }

    #[test]
    fn explicit_jobs_override_estimates_but_zero_is_an_error() {
        let resources = pc(32, 1, 1);
        let plan = compilation_jobs(resources, Compilation::Pipeline, Some(12)).unwrap();
        assert_eq!(plan.jobs, 12);
        assert!(!plan.automatic);
        assert!(compilation_jobs(resources, Compilation::Shader, Some(0)).is_err());
        assert_eq!(
            compilation_jobs(resources, Compilation::Shader, None)
                .unwrap()
                .jobs,
            1
        );
    }

    #[test]
    fn unknown_resources_use_a_small_nonzero_default() {
        let resources = Resources {
            logical_processors: 32,
            ..Resources::default()
        };
        assert_eq!(
            compilation_jobs(resources, Compilation::Shader, None)
                .unwrap()
                .jobs,
            2
        );
        assert_eq!(
            compilation_jobs(Resources::default(), Compilation::Pipeline, None)
                .unwrap()
                .jobs,
            1
        );
    }

    #[test]
    fn pipeline_admission_recovers_at_the_reserve_boundary() {
        assert!(!Compilation::Pipeline.can_start(pc(32, 20, 5)));
        assert!(!Compilation::Pipeline.can_start(pc(32, 5, 20)));
        assert!(Compilation::Pipeline.can_start(pc(32, 6, 6)));
        assert!(Compilation::Pipeline.can_start(Resources::default()));
    }
}
