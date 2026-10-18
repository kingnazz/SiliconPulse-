# SiliconPulse metrics

This document lists every metric SiliconPulse shows, how it is collected, how
much to trust it, and what it costs. The same information is compiled into the
app (`MetricCatalog` in `SiliconPulseCore`) and drives the quality badges and
tooltips in the UI, so the two must be kept in sync.

SiliconPulse only uses interfaces an unprivileged, unsandboxed user process can
call: Mach host statistics, `sysctl`, `libproc`, IOKit registry reads,
`ProcessInfo`, IOPowerSources and HTTP requests to `127.0.0.1`. It does **not**
use `powermetrics`, a privileged helper, kernel extensions, private frameworks,
or reverse-engineered SPIs.

## Quality classification

| Quality | Meaning |
|---|---|
| `exact` | A precise fact about the system, not a measurement. Example: installed RAM, PID, whether a process runs under Rosetta. |
| `systemReported` | A value macOS (or a local AI runner's own API) reports directly. SiliconPulse shows it as is. It is only as good as the reporter. |
| `calculated` | Derived by SiliconPulse from reported counters using a deterministic formula, for example a delta of cumulative CPU ticks divided by elapsed time. |
| `estimated` | A heuristic or approximation. Useful, but it can be wrong, and the UI says so. |
| `unavailable` | macOS does not expose this to an unprivileged app through an interface SiliconPulse is willing to rely on. The UI says "—" and explains why. |

Scopes:

- **SYSTEM**: whole machine (for example system GPU utilization).
- **PROCESS**: one process, or a runner's process tree.
- **MODEL**: values a runner reports about a loaded model.

SiliconPulse never shows a SYSTEM value as if it belonged to a PROCESS or MODEL.

## CPU

| Metric | Collection method | Accuracy | Cost | Permissions | Fallback |
|---|---|---|---|---|---|
| Total / user / system / idle % | `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` per-core tick counters; delta between two samples. 32-bit counters, so wrap-safe subtraction. | calculated | Very low (1 Mach call, ~10–20 ticks per core) | None | — |
| Per-core utilization | Same per-core ticks | calculated | Very low | None | — |
| Load average (1/5/15 min) | `getloadavg()` | systemReported | Negligible | None | — |
| Physical / logical cores | `sysctl hw.physicalcpu`, `hw.logicalcpu` | exact | Once at launch | None | — |
| Performance / Efficiency core counts | `sysctl hw.nperflevels`, `hw.perflevelN.{name,logicalcpu}` | exact | Once at launch | None | Hidden on Macs without perf levels (Intel). |
| P/E classification of each core | IORegistry `IODeviceTree:/cpus/*` `cluster-type` + `logical-cpu-id`, checked against the `hw.perflevel*` counts | systemReported | Once at launch | None | If the device tree is missing or disagrees with `sysctl`, SiliconPulse shows plain per-core bars and no per-cluster figures. It never guesses the order. |
| CPU model name | `sysctl machdep.cpu.brand_string` | exact | Once | None | — |

## GPU

| Metric | Collection method | Accuracy | Cost | Permissions | Fallback |
|---|---|---|---|---|---|
| System GPU utilization | IOKit `IOAccelerator` service, `PerformanceStatistics` → `Device Utilization %`. These keys are undocumented, but long-standing and widely used. | systemReported | Low (one registry property read) | None | "Unavailable" if the key is missing (for example in some VMs, which have a paravirtual GPU). |
| Renderer / tiler utilization | Same dictionary, `Renderer Utilization %`, `Tiler Utilization %` | systemReported | Low | None | Hidden when absent |
| GPU memory in use | Same dictionary, `In use system memory` | systemReported | Low | None | Hidden when absent. On Apple Silicon this is unified memory the GPU has wired, not separate VRAM. |
| GPU name / core count | `IOAccelerator` `model`, `gpu-core-count` properties | exact | Once | None | Name from CPU brand string |
| **Per-process GPU time** | IOKit: the accelerator's `IOUserClient` children carry `IOUserClientCreator` ("pid N, name") and, on Apple Silicon, an `AppUsage` array with `accumulatedGPUTime` (ns). SiliconPulse sums per PID and divides the delta by wall time. | **estimated** | Moderate (walks all GPU user clients) so it runs on the process cadence (≥ 2 s), never the fast tier | None | If `AppUsage` is absent, per-process GPU is "unavailable". SiliconPulse never splits system GPU % across processes. |

Per-process GPU time comes from undocumented properties, so it is labeled
*estimated* and shown as "GPU time share", separate from System GPU. It answers
"is this process submitting GPU work?", not "this process uses X% of the GPU".

## Neural Engine

| Metric | Collection method | Accuracy | Cost | Permissions | Fallback |
|---|---|---|---|---|---|
| ANE utilization | Not exposed publicly. `powermetrics` reports ANE *power*, not utilization, and needs root. | unavailable | — | — | The UI explains it is not exposed. |
| ANE per-process | Not exposed | unavailable | — | — | — |

## Memory (unified)

| Metric | Collection method | Accuracy | Cost | Permissions | Fallback |
|---|---|---|---|---|---|
| Installed memory | `sysctl hw.memsize` | exact | Once | None | — |
| Wired | `host_statistics64(HOST_VM_INFO64)` `wire_count × page size` | systemReported | Very low | None | — |
| Compressed | `compressor_page_count × page size` (physical memory the compressor occupies) | systemReported | Very low | None | — |
| App memory | `(internal_page_count − purgeable_count) × page size`, the same formula Activity Monitor uses | calculated | Very low | None | — |
| Used | App + Wired + Compressed | calculated | Very low | None | — |
| Cached files | `(external_page_count + purgeable_count) × page size` | calculated | Very low | None | — |
| Free | `free_count × page size` | systemReported | Very low | None | — |
| Available | Installed − Used | calculated | Very low | None | — |
| Kernel free level | `sysctl kern.memorystatus_level` (the % the memorystatus subsystem considers available) | systemReported | Negligible | None | Hidden if unreadable |
| Memory pressure | `sysctl kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical), plus a `DispatchSource.makeMemoryPressureSource` listener | systemReported | Negligible (event-driven) | None | The last dispatch-source event, else "Unknown" |
| Swap used / total | `sysctl vm.swapusage` (`xsw_usage`) | systemReported | Negligible | None | — |
| Swap-in / swap-out rate | Deltas of `swapins` / `swapouts` from `HOST_VM_INFO64` | calculated | Very low | None | — |
| Compression / decompression rate | Deltas of `compressions` / `decompressions` | calculated | Very low | None | — |
| Headroom before pressure | Available − 10% of installed memory (macOS starts compressing before memory is full) | **estimated** | Negligible | None | — |

## Thermal and power

| Metric | Collection method | Accuracy | Cost | Permissions | Fallback |
|---|---|---|---|---|---|
| Thermal state | `ProcessInfo.thermalState` (nominal/fair/serious/critical), shown as Normal / Elevated / Serious / Critical, updated on `thermalStateDidChangeNotification` | systemReported | Negligible | None | — |
| Temperatures (°C) | Only via SMC keys or private HID sensor APIs | unavailable | — | — | Not shown. Thermal *pressure* is shown instead. |
| Power source / battery % / charging | IOKit `IOPSCopyPowerSourcesInfo` | systemReported | Low (slow tier) | None | Hidden on desktops without a battery |
| Low Power Mode | `ProcessInfo.isLowPowerModeEnabled` | systemReported | Negligible | None | — |
| Energy Impact | Activity Monitor's formula is proprietary | unavailable | — | — | Not shown |
| System power (W) | `powermetrics` (root) | unavailable | — | — | Not shown |

## Disk and network

| Metric | Collection method | Accuracy | Cost | Permissions | Fallback |
|---|---|---|---|---|---|
| Disk read / write throughput | IOKit `IOBlockStorageDriver` `Statistics` → `Bytes (Read)` / `Bytes (Write)` cumulative counters, summed across drivers, delta per second | calculated | Low (a few registry reads) | None | — |
| Network download / upload | `sysctl NET_RT_IFLIST2` → `if_msghdr2.ifm_data` (64-bit `if_data64` counters). Loopback, tunnels (`utun`, `ipsec`, `gif`, `stf`), bridges and other virtual interfaces are excluded to avoid double counting. | calculated | Low (one sysctl) | None | — |
| Per-interface throughput | Same data | calculated | Low | None | — |
| Per-process disk read / write | `proc_pid_rusage(RUSAGE_INFO_V4)` `ri_diskio_bytesread/written` deltas | calculated | Part of process sampling | Same user only | "—" for other users' processes |
| Per-process network | Only through the private `NetworkStatistics` framework (used by `nettop`) | unavailable | — | — | Not shown |
| Listening TCP ports of a process | `proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` | exact | Moderate per process, so only for the inspected process and AI candidates | Same user only | Empty |

## Processes

| Metric | Collection method | Accuracy | Cost | Permissions | Fallback |
|---|---|---|---|---|---|
| Process list, PID, parent PID, user, start time, Rosetta flag | One `sysctl(KERN_PROC_ALL)` per sample into a reused buffer | exact | Low | None | — |
| Executable path | `proc_pidpath` (cached per PID + start time) | exact | Once per process | None | Short `p_comm` name |
| CPU % (100% = one core) | `proc_pidinfo(PROC_PIDTASKINFO)` `pti_total_user + pti_total_system` (Mach time units converted with `mach_timebase_info`), delta over wall time | calculated | ~1 syscall per process | Same user only (or root) | "—" with a "restricted" tooltip for other users' processes. System totals still include them. |
| Memory | `proc_pid_rusage(RUSAGE_INFO_V4)` `ri_phys_footprint`, the same "Memory" figure Activity Monitor shows | systemReported | ~1 syscall per process | Same user only | "—" |
| Threads | `pti_threadnum` | systemReported | Included above | Same user only | "—" |
| Architecture | `P_TRANSLATED` flag from `kinfo_proc` (Rosetta) | exact | Included in list | None | — |
| App name / icon / bundle ID | `NSWorkspace.runningApplications`, refreshed on launch/terminate notifications | exact | Event-driven | None | Executable name |
| Command-line arguments | `sysctl KERN_PROCARGS2`, only for AI candidates and the inspected process, cached per PID + start time | exact | Moderate, but done once per process | Same user only | Not shown |
| Children | Derived from the parent-PID map | exact | Negligible | None | — |
| Energy impact | Proprietary | unavailable | — | — | — |

## Local AI

Detection is **evidence-based**. A process name alone makes a workload a
*candidate*. It is confirmed by its runner's local API, its listening ports or
its launch arguments, and the evidence is shown in the UI. Every request goes
only to loopback addresses (`127.0.0.1`, `::1`, `localhost`); the HTTP client
refuses any other host.

| Metric | Collection method | Accuracy | Scope | Cost | Fallback |
|---|---|---|---|---|---|
| Runner present | Process table (name, path, arguments), confirmed by the runner API responding | exact (when the API confirms) / estimated (process only) | PROCESS | Discovery tier, every 5–10 s | — |
| Loaded model(s) | Ollama `GET /api/ps`; LM Studio `GET /api/v1/models` or `/api/v0/models` (`state == loaded`), falling back to `/v1/models`; llama-server `GET /props`, `/v1/models`, or `-m` / `--alias` arguments; MLX `--model` argument; other OpenAI-compatible servers `GET /v1/models` | systemReported | MODEL | 1 localhost request per runner per cycle | "No model loaded", or "unknown" when the API is unreachable |
| Model size / parameter count / quantization / family | Ollama `details`; LM Studio model metadata | systemReported | MODEL | Included | Hidden |
| Model memory | Ollama `size`; LM Studio `size_bytes` (file size of a loaded model) | systemReported | MODEL | Included | Hidden |
| GPU offload | Ollama `size_vram / size` (the same figure `ollama ps` shows); llama.cpp `-ngl` argument | systemReported | MODEL | Included | Hidden |
| Context length | Ollama `context_length`; LM Studio `loaded_context_length` or the instance config; llama-server `/props` `n_ctx`; `-c` / `--ctx-size` argument | systemReported | MODEL | Included | Hidden |
| Tokens / second | llama-server: delta of `llamacpp:tokens_predicted_total` over delta of `llamacpp:tokens_predicted_seconds_total` (`/metrics`, needs `--metrics`), or `n_decoded` deltas from `/slots` over wall time | calculated | MODEL | 1–2 localhost requests per cycle | **Unavailable for Ollama, LM Studio and MLX.** Their APIs do not expose live throughput to an observer, and SiliconPulse does not fabricate it. |
| Inference active | llama-server `/slots` `is_processing` (systemReported); a positive token delta (calculated); Ollama `expires_at` moving forward means a request was served (estimated); runner-process GPU time share or CPU above a threshold (estimated) | mixed, labeled per value | MODEL / PROCESS | Included | "Unknown" |
| Process CPU / memory / GPU time | Sum over the runner's process tree (for example `ollama serve` plus its runner children) | calculated / estimated | PROCESS | Reuses process sampling | — |
| Runtime | Process start time from `kinfo_proc` | exact | PROCESS | Included | — |
| System GPU | See GPU, always labeled SYSTEM | systemReported | SYSTEM | — | — |

## Sampling cadence

| Tier | Contents | Dashboard visible | Menu-bar popover open | Hidden (menu bar only) |
|---|---|---|---|---|
| Fast | CPU, memory, GPU utilization, disk, network, thermal | User setting (0.5 / 1 / 2 / 5 s, default 1 s) | User setting | max(setting, 2 s); 5 s when the menu bar shows no live values |
| Processes | Process table, per-process GPU time | Setting (Processes screen), else max(setting, 2 s) | max(setting, 2 s) | 5 s |
| AI discovery | Candidate arguments, listening ports, runner API polling | 2 s on the AI screen, else 5 s | 5 s | 10 s |
| Slow | Power source, battery | 10 s | 10 s | 30 s |

Low Power Mode doubles every interval. One scheduler drives all tiers, and the
inspector collects deeper data only for the selected process.
