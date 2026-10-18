#!/bin/bash
# Real Apple Silicon validation for SiliconPulse. Run on a physical Mac from the repository root.
#
#   scripts/validate-on-mac.sh                      # hardware checks, GPU vs powermetrics, screenshots
#   scripts/validate-on-mac.sh --omlx MODEL [URL]   # also check a running oMLX server (default http://127.0.0.1:8000)
#   scripts/validate-on-mac.sh --ollama MODEL       # also check a running Ollama server
#   add --allow-unload to let the runner check unload the model afterwards
#
# GPU comparison: `powermetrics` needs sudo; you are asked for your password once. Without it the
# GPU trace is still recorded, just not compared. Nothing is uploaded; results land in validation-<time>/.
set -uo pipefail

RUNNER="" MODEL="" BASE="" ALLOW_UNLOAD=0
while [ $# -gt 0 ]; do
  case "$1" in
    --omlx)
      RUNNER=omlx; MODEL=$2; BASE=http://127.0.0.1:8000; shift 2
      if [[ ${1:-} == http* ]]; then BASE=$1; shift; fi ;;
    --ollama) RUNNER=ollama; MODEL=$2; BASE=http://127.0.0.1:11434; shift 2 ;;
    --allow-unload) ALLOW_UNLOAD=1; shift ;;
    *) echo "Unknown option $1"; exit 2 ;;
  esac
done

OUT="validation-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
echo "Writing results to $OUT/"

# 1. Machine (model and chip only; no names).
{
  echo "model: $(sysctl -n hw.model)"
  echo "chip: $(sysctl -n machdep.cpu.brand_string)"
  echo "memory: $(( $(sysctl -n hw.memsize) / 1073741824 )) GB"
  echo "perf levels: $(sysctl -n hw.nperflevels 2>/dev/null || echo 1)"
  echo "P cores: $(sysctl -n hw.perflevel0.logicalcpu 2>/dev/null || echo -)  E cores: $(sysctl -n hw.perflevel1.logicalcpu 2>/dev/null || echo -)"
  sw_vers
} | tee "$OUT/machine.txt"

# 2. Build and run the hardware checks while a GPU load runs, with powermetrics sampling alongside.
swift build -c release > "$OUT/build.log" 2>&1 || { echo "Build failed, see $OUT/build.log"; exit 1; }
swift build --build-tests > "$OUT/build-tests.log" 2>&1 || { echo "Test build failed, see $OUT/build-tests.log"; exit 1; }

LOAD=""
if [ -n "$RUNNER" ]; then
  echo "Generating with $RUNNER during the GPU trace…"
  ( while true; do scripts/real-runner-load.sh "$RUNNER" "$BASE" "$MODEL"; done ) > /dev/null 2>&1 &
  LOAD=$!
else
  echo "Tip: start a GPU workload now (a model generating, a game, a video export) for a meaningful GPU comparison."
  sleep 5
fi

POWER=""
if sudo -v 2>/dev/null; then
  sudo powermetrics --samplers gpu_power -i 1000 -n 16 > "$OUT/powermetrics.txt" 2>&1 &
  POWER=$!
fi
SILICONPULSE_VALIDATE_MAC=1 SILICONPULSE_VALIDATE_SECONDS=15 swift test --skip-build --filter RealMacValidationTests 2>&1 | tee "$OUT/hardware-test.log"
[ -n "$POWER" ] && wait "$POWER"
[ -n "$LOAD" ] && kill "$LOAD" 2>/dev/null

echo
echo "== GPU utilization over the same 15 s =="
SP=$(grep "VALIDATE gpu-mean" "$OUT/hardware-test.log" | awk '{print $3}')
echo "SiliconPulse (IOAccelerator Device Utilization %): ${SP:-n/a}"
if [ -s "$OUT/powermetrics.txt" ]; then
  PM=$(grep -i "GPU HW active residency" "$OUT/powermetrics.txt" | sed -E 's/.*: *([0-9.]+)%.*/\1/' | awk '{s+=$1; n++} END {if (n) printf "%.3f", s/n/100}')
  echo "powermetrics (GPU HW active residency):            ${PM:-n/a}"
  echo "These measure related but not identical things; expect them to track each other, within roughly 10–15 points."
fi

# 3. A real runner, if given: detection, attribution, activity, idle (and unload when allowed).
if [ -n "$RUNNER" ]; then
  PID=$(lsof -nP -iTCP:"${BASE##*:}" -sTCP:LISTEN -t 2>/dev/null | head -1)
  echo
  echo "== $RUNNER lifecycle (server PID ${PID:-unknown}) =="
  SILICONPULSE_REAL_RUNNER=$RUNNER SILICONPULSE_REAL_BASE=$BASE SILICONPULSE_REAL_MODEL=$MODEL \
  SILICONPULSE_REAL_SERVER_PID=${PID:-0} SILICONPULSE_REAL_ALLOW_UNLOAD=$ALLOW_UNLOAD \
    swift test --skip-build --filter RealRunnerTests 2>&1 | tee "$OUT/runner-test.log" | grep -E "REAL-RUNNER|passed|failed|error"
fi

# 4. Screenshots of every screen in light and dark, with the computer and account names left out.
scripts/build-app.sh > "$OUT/bundle.log" 2>&1
build/SiliconPulse.app/Contents/MacOS/SiliconPulse --screenshots "$PWD/$OUT/screenshots" > "$OUT/screenshots.log" 2>&1 &
APP=$!
for _ in $(seq 1 240); do kill -0 $APP 2>/dev/null || break; sleep 1; done
kill $APP 2>/dev/null

echo
echo "Done. Review $OUT/screenshots before sharing them: process names in the Processes screen are real."
grep -h "VALIDATE machine\|VALIDATE cores" "$OUT/hardware-test.log"
grep -E "Executed|error|failed" "$OUT/hardware-test.log" | tail -3
