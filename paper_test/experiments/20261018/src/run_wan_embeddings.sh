#!/usr/bin/env bash
set -euo pipefail

task_python=/home/zhangcheng/miniconda3/envs/dfot/bin/python
task_script=/home/zhangcheng/DiT-FA/scripts/capture_trajectories.py
task_output=/10T/zhangcheng/flopa_evaluation_20261018
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1

for ((attempt = 0; attempt < 2880; attempt++)); do
    if [[ -f "$task_output/wan_assets_complete.json" ]]; then
        exec "$task_python" -u "$task_script" --model wan --output "$task_output" \
            --embeddings-only
    fi
    sleep 30
done
echo 'Wan asset verification did not complete within 24 hours' >&2
exit 1
