#!/usr/bin/env bash
# Launches SiliconPulse in scripted profile mode and cross-checks its CPU and memory with ps.
# Usage: scripts/profile-app.sh build/SiliconPulse.app profile
set -uo pipefail

APP="${1:-build/SiliconPulse.app}"
OUT="${2:-profile}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
BIN="$APP/Contents/MacOS/SiliconPulse"

defaults write app.siliconpulse.SiliconPulse hasCompletedOnboarding -bool true || true

"$BIN" --profile "$OUT" > "$OUT/app-stdout.log" 2>&1 &
PID=$!
echo "Launched SiliconPulse (pid $PID)"

# Independent cross-check: ps every 5 s (RSS in KB, cumulative CPU time).
{
  echo "elapsed_s rss_kb cputime"
  start=$(date +%s)
  while kill -0 "$PID" 2>/dev/null; do
    now=$(date +%s)
    line=$(ps -o rss=,time= -p "$PID" 2>/dev/null || true)
    [ -n "$line" ] && echo "$((now - start)) $line"
    sleep 5
  done
} > "$OUT/ps.log" &
PS_LOGGER=$!

# Call-tree samples of the app itself, taken while the dashboard is visible and while it is hidden.
# Phase timing comes from ProfileRunner: overview 6–36 s, window closed ≈ 110–150 s.
take_sample() {
  local at="$1" name="$2"
  while [ "$(( $(date +%s) - START ))" -lt "$at" ]; do kill -0 "$PID" 2>/dev/null || return; sleep 1; done
  sample "$PID" 8 -file "$OUT/sample-$name.txt" > /dev/null 2>&1 || true
}
START=$(date +%s)
( take_sample 14 overview; take_sample 118 hidden ) &
SAMPLER=$!

# The scripted run takes about three and a half minutes; stop it if it hangs.
for _ in $(seq 1 360); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "Profile run did not finish in time; capturing state and stopping it." | tee -a "$OUT/problems.txt"
  footprint "$PID" > "$OUT/footprint.txt" 2>&1 || true
  sample "$PID" 3 -file "$OUT/sample.txt" > /dev/null 2>&1 || true
  kill "$PID" || true
fi
wait "$PID"
STATUS=$?
kill "$PS_LOGGER" "$SAMPLER" 2>/dev/null || true

echo "Exit status: $STATUS"
echo "---- ps cross-check ----"
cat "$OUT/ps.log"
echo "---- report ----"
cat "$OUT/report.md" 2>/dev/null || { echo "No report produced"; cat "$OUT/app-stdout.log"; exit 1; }
for f in "$OUT"/sample-*.txt; do
  [ -f "$f" ] || continue
  echo "---- $(basename "$f"): heaviest frames (top of stack) ----"
  sed -n '/Sort by top of stack/,/Binary Images/p' "$f" | head -45
done
ls -la "$OUT"
if [ "$STATUS" -ne 0 ]; then echo "SiliconPulse exited with status $STATUS"; cat "$OUT/app-stdout.log"; exit 1; fi
if ! grep -q "Problems: none" "$OUT/report.md"; then echo "Profile reported problems"; exit 1; fi
