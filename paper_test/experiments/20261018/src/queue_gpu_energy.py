"""Submit energy measurements only when the fixed GPU is idle and reserved by our lock."""

import fcntl
import json
import os
import subprocess
import sys
from pathlib import Path

from capture_trajectories import MODELS, wait_for_gpu, write_json


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
os.environ['CUDA_VISIBLE_DEVICES'] = '0'
target = ROOT / 'baselines/gpu_energy'
target.mkdir(parents=True, exist_ok=True)
queue_lock = (target / 'queue.lock').open('w')
fcntl.flock(queue_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
for model, config in MODELS.items():
    for pixel in config['pixels']:
        name = f'{model}_p{pixel}'
        destination = target / (name + '.json')
        if destination.exists():
            assert json.loads(destination.read_text())['status'] == 'pass_energy_only'
            continue
        write_json(target / 'queue_state.json', {'state': 'waiting_idle_gpu', 'point': name})
        wait_for_gpu(target)
        with (ROOT / 'gpu_capture_timing.lock').open('w') as gpu_lock:
            fcntl.flock(gpu_lock, fcntl.LOCK_EX)
            wait_for_gpu(target)
            layer = config['layers'][1]
            vector = ROOT / model / f'evaluation_p{pixel}_seed301/l{layer:02d}_s15.pt'
            command = [sys.executable, '-u', str(Path(__file__).with_name(
                'benchmark_sdpa_energy.py')), '--vector', str(vector), '--baseline',
                str(ROOT / f'baselines/cuda/{name}.json'), '--output', str(destination)]
            write_json(target / 'queue_state.json', {'state': 'running', 'point': name})
            with (target / (name + '.log')).open('w') as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode:
                write_json(target / 'queue_state.json', {
                    'state': 'failed', 'point': name, 'log': str(target / (name + '.log')),
                })
                raise RuntimeError('GPU energy failed: ' + name)
        print('ENERGY_POINT_COMPLETE', name, flush=True)
write_json(target / 'queue_state.json', {'state': 'complete', 'points': 10})
