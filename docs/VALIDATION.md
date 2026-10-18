# Validation

What has been checked, where, and what still needs a physical Apple Silicon Mac.

## Environments

| Where | Hardware | What it can prove |
|---|---|---|
| CI `macos` job | GitHub Actions Apple M1 **virtual machine** (`Apple Virtual Machine 1`), 3 vCPUs, 7 GB, macOS 15.7, paravirtual GPU | Collectors, sampling loop, soak, process table, AI detection against mocks, UI screenshots, menu bar item |
| CI `real-runner` job | Same virtual Mac. The paravirtual GPU **does** run Metal (Ollama and MLX use it) but does not publish `Device Utilization %` | Real runtimes serving a real model, with SiliconPulse watching through its real collectors |
| Your Mac | Physical Apple Silicon | System GPU utilization, P/E core clusters, your own runners, real-display rendering |

SiliconPulse has **not yet been run on physical Apple Silicon by its authors**. The checks below that need it are scripted (`scripts/validate-on-mac.sh`) and have not been executed yet.

## Real local AI runtimes (CI virtual Mac)

Each `real-runner` leg installs a real runtime and model, then `RealRunnerTests` drives it like a user would, while SiliconPulse observes it through `SystemSampler` (real process scan, arguments, listening sockets) and `AIMonitor` (real HTTP):

1. warm-up generation, then **detection and attribution**;
2. a 400-token generation (**activity**);
3. **idle** after it finishes;
4. **model unload**;
5. **server exit**.

| Check | oMLX (pinned v0.7.1rc1 commit, MLX on `Device(gpu, 0)`) | Ollama (Homebrew) |
|---|---|---|
| Model | `mlx-community/Qwen2.5-0.5B-Instruct-4bit` | `qwen2.5:0.5b` |
| Runner identification | **oMLX**, not "OpenAI-compatible" | Ollama |
| Model name | `Qwen2.5-0.5B-Instruct-4bit` from `/v1/models/status` | `qwen2.5:0.5b` from `/api/ps` |
| Endpoint | `127.0.0.1:8123`, found from the server's listening socket (non-default port) | `127.0.0.1:11434` |
| Process grouping | `omlx serve` server process | `ollama serve` plus its `ollama runner` child |
| Process memory | ≈ 547 MB, separate from the 368 MB model size oMLX reports | ≈ 675 MB |
| While generating | "Inference active (oMLX reports 1 request(s) processing)" | "Likely inferring (runner processes have GPU work 73% of the time)", CPU ≈ 218% |
| Tokens/sec | oMLX's own session average, labeled "Session average reported by oMLX" (systemReported) | Unavailable: Ollama does not expose it |
| Idle after the request | Idle | Idle |
| Model unload | "No model loaded", process memory drops to ≈ 163 MB | "No model loaded", process memory drops to ≈ 17 MB |
| Server exit | Workload removed | Workload removed |

Both legs passed in two consecutive CI runs. Screenshots taken while each model served requests are in each run's `real-runner-<runtime>` artifact.

Not covered: LM Studio, llama.cpp and MLX (`mlx_lm.server`) were not run for real; they are covered by unit tests and, for llama.cpp, by the API mock.

## Menu bar item

Screenshot mode clicks SiliconPulse's real `NSStatusItem` button, and captures the `MenuBarExtraWindow` it opens (`menubar-clicked-{light,dark}.png`, 312 × 328 pt) with live data. This includes a real oMLX model in the `real-runner` job.

Still to check by hand on a real display:

- hover highlights;
- Retina rendering;
- the popover's position under the menu bar.

## GPU (needs your Mac)

The virtual Mac's paravirtual GPU does not publish `Device Utilization %`, so SiliconPulse correctly shows "Not reported on this Mac" there. On physical Apple Silicon:

```sh
scripts/validate-on-mac.sh                       # GPU trace vs powermetrics, P/E cores, screenshots
scripts/validate-on-mac.sh --omlx <model-id>     # also your oMLX server (default http://127.0.0.1:8000)
scripts/validate-on-mac.sh --ollama <model>      # also your Ollama server
```

The script:

- records the Mac model and chip, without your names;
- runs `RealMacValidationTests`:
  - P/E core counts and per-core kinds against `hw.perflevel0/1.logicalcpu`;
  - a 15 s trace of `IOAccelerator` `Device Utilization %`, renderer and tiler;
- samples `powermetrics --samplers gpu_power` over the same 15 s (needs sudo) and prints both averages;
- runs the runner lifecycle against your server, if you name one. Unloading the model and stopping the server only happen with `--allow-unload`, and stopping is never done on your Mac;
- captures every screen in light and dark.

`Device Utilization %` and powermetrics' *GPU HW active residency* measure related but different things, so expect them to track each other within roughly 10–15 points under load, not to match exactly.

Per-process GPU time is the share of time a process had GPU work queued. It stays labeled *estimated* and is never presented as utilization; the test asserts the label.

## Results to fill in after running on a physical Mac

| | |
|---|---|
| Mac model / chip | |
| macOS | |
| P/E cores detected vs `hw.perflevel*` | |
| GPU mean, SiliconPulse vs powermetrics | |
| Runner and model tested | |
| Lifecycle result | |
