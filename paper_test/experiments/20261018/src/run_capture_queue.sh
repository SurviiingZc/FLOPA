#!/usr/bin/env bash
set -euo pipefail

task_python=/home/zhangcheng/miniconda3/envs/dfot/bin/python
task_script=/home/zhangcheng/DiT-FA/scripts/capture_trajectories.py
task_output=/10T/zhangcheng/flopa_evaluation_20261018
export CUDA_VISIBLE_DEVICES=0
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export PYTHONUNBUFFERED=1

while [[ ! -f "$task_output/pixart/embeddings.pt" ]]; do
    sleep 15
done
"$task_python" -u "$task_script" --model pixart --output "$task_output" --allow-shared-capture \
    > "$task_output/pixart_capture.log" 2>&1

while [[ ! -f "$task_output/wan/embeddings.pt" ]]; do
    sleep 30
done
"$task_python" -u "$task_script" --model wan --output "$task_output" --allow-shared-capture \
    > "$task_output/wan_capture.log" 2>&1
