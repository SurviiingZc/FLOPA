"""Apply the user's GPU-only baseline scope and audit existing GPU measurements."""

import hashlib
import json
import math
import os
import signal
import statistics
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
SOURCE = Path('/home/zhangcheng/DiT-FA/scripts')
UUID = 'GPU-d32726df-59e7-0d6a-fb9c-c3cde370d244'
MODELS = {'pixart': (16, 72, 14, [512, 768, 1024, 1536, 2048]),
          'wan': (12, 128, 15, [256, 384, 512, 768, 1024])}


def write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(data, indent=4, ensure_ascii=False) + '\n')
    temporary.replace(path)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(8 << 20), b''):
            result.update(block)
    return result.hexdigest()


def main():
    scope = {
        'updated_utc': datetime.now(timezone.utc).isoformat(),
        'cpu_baseline_enabled': False, 'gpu_baseline_enabled': True,
        'main_figure_platforms': ['GPU', 'FLOPA'],
        'reason': 'User removed the CPU performance baseline on 2026-10-19',
        'cpu_reference_math_remains_required': True,
        'historical_cpu_measurements': 'retained, excluded from paper comparisons',
    }
    write(ROOT / 'evaluation_scope.json', scope)
    stopped = []
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            if process.stat().st_uid != os.getuid():
                continue
            arguments = (process / 'cmdline').read_bytes().decode().split('\0')
            if str(ROOT) not in arguments:
                continue
            scripts = [Path(value).name for value in arguments if value.endswith('.py')]
            queue = 'run_final_cpu_queue.py' in scripts
            cpu_device = ('--device' in arguments and
                          arguments[arguments.index('--device') + 1] == 'cpu')
            queue = queue or (cpu_device and any(name in scripts for name in
                                               ('run_baseline_queue.py', 'benchmark_sdpa.py')))
            if queue:
                os.kill(int(process.name), signal.SIGTERM)
                stopped.append({'pid': int(process.name), 'arguments': arguments[:-1]})
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    for folder in ('cpu', 'cpu_after_shadow'):
        write(ROOT / 'baselines' / folder / 'queue_state.json', {
            'state': 'cancelled_by_user', 'scope': scope,
        })
    write(ROOT / 'cpu_baseline_cancellation.json', {'scope': scope, 'stopped': stopped})
    rows = []
    for model, (heads, dim, layer, pixels) in MODELS.items():
        for n, pixel in zip((1024, 2304, 4096, 9216, 16384), pixels):
            path = ROOT / 'baselines/cuda' / f'{model}_p{pixel}.json'
            report = json.loads(path.read_text())
            vector = ROOT / model / f'evaluation_p{pixel}_seed301/l{layer:02d}_s15.pt'
            assert report['status'] == 'pass_timing_only'
            assert report['metadata']['shape'] == [1, heads, n, dim]
            assert report['metadata']['branch'] == 'conditional'
            assert report['metadata']['seed'] == 301
            assert report['metadata']['causal'] is False and report['metadata']['mask'] is None
            assert report['device'] == 'cuda' and report['dtype'] == 'torch.float16'
            assert report['gpu_uuid'] == UUID and report['tf32'] is False
            assert report['warmup'] == 20 and report['batches'] == 3
            assert report['repetitions_per_batch'] == 30
            batches = report['samples_ms']
            assert len(batches) == 3 and all(len(batch) == 30 for batch in batches)
            samples = [value for batch in batches for value in batch]
            assert all(math.isfinite(value) and value > 0 for value in samples)
            assert math.isclose(statistics.median(samples), report['median_ms'], abs_tol=1e-12)
            assert report['vector_sha256'] == digest(vector)
            selected = report['gpu_backend']
            valid = [trial for trial in report['pilot'] if 'median_ms' in trial]
            assert selected['median_ms'] == min(trial['median_ms'] for trial in valid)
            trace = report['actual_operator_trace']
            operator = {'FLASH_ATTENTION': 'aten::_scaled_dot_product_flash_attention',
                        'EFFICIENT_ATTENTION': 'aten::_scaled_dot_product_efficient_attention'}
            assert operator[selected['backend']] in trace
            assert selected['relative_l2'] <= 0.005
            rows.append({
                'model': model, 'n': n, 'heads': heads, 'd': dim,
                'gpu_median_ms': report['median_ms'], 'gpu_q25_ms': report['q25_ms'],
                'gpu_q75_ms': report['q75_ms'], 'backend': selected['backend'],
                'dtype': report['dtype'], 'warmup': 20, 'timed_samples': 90,
                'gpu_uuid': UUID, 'vector_sha256': report['vector_sha256'],
                'source': str(path), 'source_sha256': digest(path),
            })
    result = {'status': 'pass_metadata_and_input_audit', 'scope': scope,
              'gpu': 'RTX A6000', 'measurement': 'resident full multihead SDPA, CUDA events',
              'points': len(rows), 'rows': rows}
    write(ROOT / 'gpu_baseline_summary.json', result)
    print(json.dumps({'stopped_cpu_workers': stopped, 'gpu_points': len(rows),
                      'latencies': [(row['model'], row['n'], row['gpu_median_ms'])
                                    for row in rows]}, ensure_ascii=False))


if __name__ == '__main__':
    main()
