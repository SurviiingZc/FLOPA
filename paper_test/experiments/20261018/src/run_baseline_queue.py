"""Run resident baselines as true trajectory vectors become available."""

import argparse
import fcntl
import os
import subprocess
import sys
import time
from pathlib import Path

from capture_trajectories import MODELS, wait_for_gpu, write_json


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--device', choices=['cpu', 'cuda'], required=True)
    parser.add_argument('--diagnostic-precision', action='store_true')
    args = parser.parse_args()
    target = args.output / 'baselines' / args.device
    target.mkdir(parents=True, exist_ok=True)
    lock_handle = (target / 'worker.lock').open('w')
    fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    write_json(target / 'queue_state.json', {
        'status': 'running', 'precision_gate_is_diagnostic': args.diagnostic_precision,
    })
    pending = {(model, pixels) for model, config in MODELS.items()
               for pixels in config['pixels']}
    for _ in range(48 * 60 * 2):
        if args.device == 'cuda':
            captures_finished = all(
                (args.output / model / 'main_capture_complete.json').exists() or
                (args.output / model / 'capture_complete.json').exists() or
                (not args.diagnostic_precision and
                 (args.output / model / 'numerical_gate_failed.json').exists())
                for model in MODELS)
            if not captures_finished:
                time.sleep(30)
                continue
        for model, pixels in sorted(pending):
            destination = target / f'{model}_p{pixels}.json'
            if destination.exists():
                pending.remove((model, pixels))
                continue
            folder = args.output / model / f'evaluation_p{pixels}_seed301'
            if not (folder / 'complete.json').exists():
                if (not args.diagnostic_precision and
                        (args.output / model / 'numerical_gate_failed.json').exists()):
                    write_json(target / f'{model}_p{pixels}_unmeasured.json', {
                        'status': 'unmeasured', 'reason': 'capture stopped at numerical gate',
                    })
                    pending.remove((model, pixels))
                continue
            vector = folder / f"l{MODELS[model]['layers'][1]:02d}_s15.pt"
            if args.device == 'cuda':
                wait_for_gpu(target)
                gpu_lock = (args.output / 'gpu_capture_timing.lock').open('w')
                fcntl.flock(gpu_lock, fcntl.LOCK_EX)
                wait_for_gpu(target)
            command = [sys.executable, '-u', str(Path(__file__).with_name('benchmark_sdpa.py')),
                       '--vector', str(vector), '--output', str(destination),
                       '--device', args.device]
            print('BASELINE_START', model, pixels, args.device, flush=True)
            with destination.with_suffix('.log').open('w') as log:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            if args.device == 'cuda':
                fcntl.flock(gpu_lock, fcntl.LOCK_UN)
                gpu_lock.close()
            if result.returncode != 0:
                write_json(destination.with_suffix('.failure.json'), {
                    'status': 'failed_baseline', 'exit_code': result.returncode,
                    'log': str(destination.with_suffix('.log')),
                })
                raise RuntimeError('Baseline failed: ' + str(destination))
            print('BASELINE_COMPLETE', model, pixels, args.device, flush=True)
            pending.remove((model, pixels))
            obsolete = target / f'{model}_p{pixels}_unmeasured.json'
            if obsolete.exists():
                obsolete.rename(obsolete.with_suffix('.superseded.json'))
        if not pending:
            write_json(target / 'queue_complete.json', {'status': 'complete'})
            write_json(target / 'queue_state.json', {'status': 'complete'})
            return
        time.sleep(30)
    raise RuntimeError('Baseline queue reached its 48-hour limit')


if __name__ == '__main__':
    main()
