#!/usr/bin/env bash
set -euo pipefail

task_python=/home/zhangcheng/miniconda3/envs/dfot/bin/python
task_source=/home/zhangcheng/DiT-FA/scripts
task_output=/10T/zhangcheng/flopa_evaluation_20261018
export CUDA_VISIBLE_DEVICES=0
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export PYTHONUNBUFFERED=1
export OPENBLAS_NUM_THREADS=1
export OMP_NUM_THREADS=8

for task_model in pixart wan; do
    "$task_python" -u "$task_source/capture_trajectories.py" --model "$task_model" \
        --output "$task_output" --allow-shared-capture --diagnostic-precision --main-only \
        > "$task_output/${task_model}_capture_resume_20261019.log" 2>&1
done
