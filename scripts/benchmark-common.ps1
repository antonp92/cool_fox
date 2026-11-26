# Native queries used by the benchmark; no administrator access is required.
function Initialize-BenchmarkNative {
    if ('VictoryBenchmark.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace VictoryBenchmark {
    [StructLayout(LayoutKind.Sequential)] public struct Performance {
        public uint Size;
        public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable;
        public UIntPtr SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize;
        public uint HandleCount, ProcessCount, ThreadCount;
    }
    public class CpuSet {
        public int Group, Logical, Core, Cache, Efficiency;
        public bool Parked;
    }
    public static class Native {
        [DllImport("psapi.dll", SetLastError=true)]
        public static extern bool GetPerformanceInfo(out Performance info, uint size);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetSystemCpuSetInformation(IntPtr data, uint size, out uint needed, IntPtr process, uint flags);
        public static CpuSet[] CpuSets() {
            uint needed;
            GetSystemCpuSetInformation(IntPtr.Zero, 0, out needed, new IntPtr(-1), 0);
            if (needed == 0) return new CpuSet[0];
            uint capacity = needed;
            IntPtr data = Marshal.AllocHGlobal(checked((int)capacity));
            try {
                if (!GetSystemCpuSetInformation(data, capacity, out needed, new IntPtr(-1), 0) || needed > capacity)
                    return new CpuSet[0];
                var sets = new List<CpuSet>();
                for (int at=0; at+32<=needed;) {
                    int size = Marshal.ReadInt32(data, at);
                    if (size < 32 || size > needed-at) break;
                    if (Marshal.ReadInt32(data, at+4)==0) sets.Add(new CpuSet {
                        Group=(ushort)Marshal.ReadInt16(data,at+12),
                        Logical=Marshal.ReadByte(data,at+14), Core=Marshal.ReadByte(data,at+15),
                        Cache=Marshal.ReadByte(data,at+16), Efficiency=Marshal.ReadByte(data,at+18),
                        Parked=(Marshal.ReadByte(data,at+19)&1)!=0
                    });
                    at+=size;
                }
                return sets.ToArray();
            } finally { Marshal.FreeHGlobal(data); }
        }
    }
}
'@
}

function Get-BenchmarkMemory {
    $info = New-Object VictoryBenchmark.Performance
    if (-not [VictoryBenchmark.Native]::GetPerformanceInfo([ref]$info, [Runtime.InteropServices.Marshal]::SizeOf($info))) {
        throw 'GetPerformanceInfo failed.'
    }
    $page = $info.PageSize.ToUInt64()
    [pscustomobject]@{
        PhysicalTotalBytes = $info.PhysicalTotal.ToUInt64() * $page
        PhysicalAvailableBytes = $info.PhysicalAvailable.ToUInt64() * $page
        CommitTotalBytes = $info.CommitTotal.ToUInt64() * $page
        CommitLimitBytes = $info.CommitLimit.ToUInt64() * $page
        CommitAvailableBytes = ($info.CommitLimit.ToUInt64() - $info.CommitTotal.ToUInt64()) * $page
    }
}

function Resolve-BenchmarkDataPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Data path crosses a link: $ancestor" }
            if ((Test-Path -LiteralPath (Join-Path $ancestor '.git')) -or
                (Test-Path -LiteralPath (Join-Path $ancestor '.victory-root'))) {
                throw "Benchmark data must be outside repositories: $full"
            }
        }
        $parent = [IO.Directory]::GetParent($ancestor)
        $ancestor = if ($parent) { $parent.FullName } else { $null }
    }
    $full
}
