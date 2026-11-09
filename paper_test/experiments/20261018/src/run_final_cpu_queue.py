"""Repeat CPU timings after this experiment's integer-reference workers have exited."""

import argparse
import fcntl
import json
import subprocess
import sys
import time
from pathlib import Path

from capture_trajectories import MODELS, write_json


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    scope_path = args.output / 'evaluation_scope.json'
    if scope_path.exists() and not json.loads(scope_path.read_text()).get(
            'cpu_baseline_enabled', True):
        print('CPU_BASELINE_CANCELLED_BY_USER', flush=True)
        return
    target = args.output / 'baselines/cpu_after_shadow'
    target.mkdir(parents=True, exist_ok=True)
    lock = (target / 'worker.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    required = [args.output / f'diagnostic_export_{model}_complete.json' for model in MODELS]
    write_json(target / 'queue_state.json', {
        'state': 'waiting_for_this_experiment_shadow_workers',
        'reason': 'earlier CPU timing may overlap integer-reference construction',
    })
    for _ in range(48 * 60 * 2):
        if all(path.exists() for path in required):
            break
        time.sleep(30)
    else:
        raise RuntimeError('CPU repeat waited more than 48 hours for integer references')
    for model, config in MODELS.items():
        for pixel in config['pixels']:
            destination = target / f'{model}_p{pixel}.json'
            if destination.exists():
                continue
            vector = args.output / model / f'evaluation_p{pixel}_seed301' / (
                f"l{config['layers'][1]:02d}_s15.pt")
            command = [sys.executable, '-u', str(Path(__file__).with_name('benchmark_sdpa.py')),
                       '--vector', str(vector), '--output', str(destination), '--device', 'cpu']
            print('CPU_REPEAT_START', model, pixel, flush=True)
            with destination.with_suffix('.log').open('w') as log:
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
            print('CPU_REPEAT_COMPLETE', model, pixel, flush=True)
    write_json(target / 'queue_state.json', {
        'state': 'complete', 'own_shadow_workers_finished': True,
        'host_exclusivity_claimed': False, 'host_load_recorded_in_each_result': True,
    })


if __name__ == '__main__':
    main()
