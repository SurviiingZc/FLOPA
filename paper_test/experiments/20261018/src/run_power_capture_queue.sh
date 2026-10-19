#!/usr/bin/env bash
set -euo pipefail

task_python=/home/zhangcheng/miniconda3/envs/dfot/bin/python
task_source=/home/zhangcheng/DiT-FA/scripts
task_output=/10T/zhangcheng/flopa_evaluation_20261018
export CUDA_VISIBLE_DEVICES=0
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=4

# The existing main-capture process must finish before this one uses the GPU.
while ps -p 535079 -o stat= | grep -q '^[^Z]'; do
    sleep 30
done
for task_model in pixart wan; do
    "$task_python" -u "$task_source/capture_trajectories.py" --model "$task_model" \
        --output "$task_output" --allow-shared-capture --diagnostic-precision \
        --microbench-calibration > "$task_output/${task_model}_power_capture.log" 2>&1
done
