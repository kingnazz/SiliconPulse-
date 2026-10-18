#!/bin/bash
# One generation request against a real local runner, standing in for a user (CI real-runner job only).
# Usage: real-runner-load.sh ollama|omlx BASE_URL MODEL
set -u
runner=$1 base=$2 model=$3
prompt="Write a short paragraph about lighthouses."
if [ "$runner" = "ollama" ]; then
  curl -s -m 120 "$base/api/generate" -d "{\"model\":\"$model\",\"prompt\":\"$prompt\",\"stream\":false,\"options\":{\"num_predict\":160}}" > /dev/null
else
  curl -s -m 120 "$base/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$model\",\"max_tokens\":160,\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}]}" > /dev/null
fi
