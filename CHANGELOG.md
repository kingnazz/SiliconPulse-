# Changelog

## 1.0.0 — 2026-10-20

The first release of SiliconPulse, a native macOS monitor for Apple Silicon and local AI workloads.

- **Overview:** the Mac's state at a glance. CPU, GPU and unified memory with live charts; memory pressure, thermal state and swap; the active local model; and the busiest processes.
- **Local AI:** detects oMLX, Ollama, LM Studio, llama.cpp, MLX and OpenAI-compatible servers on this Mac. It shows the loaded model, its memory, whether it is generating, and the runner's own CPU, memory and GPU time. Tokens/sec appears only when a runner actually reports it, and system GPU is never attributed to a model.
- **Processes:** a native table with filters, search, high-usage highlighting, AI-process marking and an inspector.
- **Memory, Compute, Disk & Network and History** screens, with a 60 s, 5 min or 30 min window.
- **Menu bar:** a live summary plus a popover with the machine's health, CPU, GPU and memory, and the active model.
- **Honest numbers:** every value has a quality class (exact, reported, calculated, estimated or unavailable) and a scope (whole Mac, runner process or model), shown when you hover it.
- **Lightweight:** one sampling loop that slows down when nothing is on screen; under 1% CPU while it sits in the menu bar.
- **Private:** no telemetry, accounts or uploads. The only network requests go to AI runners on 127.0.0.1.
- Opens at login if you want it to, starting quietly in the menu bar.
