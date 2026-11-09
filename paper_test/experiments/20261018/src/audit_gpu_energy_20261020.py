"""Audit acquired GPU board-energy traces without reclassifying them as exclusive."""

import json
import statistics
from pathlib import Path

from capture_trajectories import MODELS, sha, write_json


root = Path('/10T/zhangcheng/flopa_evaluation_20261018')
results = {}
for model, config in MODELS.items():
    for pixel in config['pixels']:
        path = root / 'baselines/gpu_energy' / f'{model}_p{pixel}.json'
        if not path.exists():
            continue
        report = json.loads(path.read_text())
        n = report['shape'][2]
        assert report['status'] == 'pass_energy_only'
        assert report['shape'] == [1, config['heads'], n, config['dim']]
        assert report['shared_environment_authorized'] is True
        assert report['energy_method'] == 'NVML board-power trapezoidal integration'
        baseline_path = root / 'baselines/cuda' / f'{model}_p{pixel}.json'
        baseline = json.loads(baseline_path.read_text())
        assert sha(baseline_path) == report['baseline_sha256']
        assert baseline['vector_sha256'] == report['vector_sha256']
        assert baseline['gpu_uuid'] == report['gpu_uuid']
        vector = root / model / f'evaluation_p{pixel}_seed301' / (
            f"l{config['layers'][1]:02d}_s15.pt")
        assert sha(vector) == report['vector_sha256']
        assert len(report['trials']) == 3
        for trial in report['trials']:
            assert trial['wall_s'] >= 10 and trial['actual_sdpa_calls'] > 0
            assert trial['actual_sdpa_calls'] % 32 == 0
            assert len(trial['samples']) > 50
            expected = trial['energy_j'] / trial['actual_sdpa_calls'] * 1e6
            assert abs(expected - trial['gross_uj_per_sdpa']) < 1e-7
            assert abs(trial['energy_j'] / trial['wall_s'] - trial['mean_board_w']) < 1e-9
            assert trial['background_process_samples']
            readings = trial['samples']
            if 'endpoint_board_power_w' in trial:
                start, stop = trial['window_start_monotonic_s'], trial['window_end_monotonic_s']
                first, last = trial['endpoint_board_power_w']
                points = [[start, first]] + [item[:2] for item in readings
                                            if start < item[0] < stop] + [[stop, last]]
                energy = sum((b[0] - a[0]) * (a[1] + b[1]) / 2
                             for a, b in zip(points, points[1:]))
                assert abs(energy - trial['energy_j']) < 1e-7
            else:
                # Early records predate explicit endpoints; check the interior trace average.
                energy = sum((b[0] - a[0]) * (a[1] + b[1]) / 2
                             for a, b in zip(readings, readings[1:]))
                mean = energy / (readings[-1][0] - readings[0][0])
                assert abs(mean - trial['mean_board_w']) / mean < 0.02
        median = statistics.median(item['gross_uj_per_sdpa'] for item in report['trials'])
        assert abs(median - report['median_gross_uj_per_sdpa']) < 1e-7
        results[f'{model}_n{n}'] = {
            'source': str(path), 'sha256': sha(path), 'median_gross_uj_per_sdpa': median,
            'trials': report['trials'], 'shared_environment': True,
            'energy_method': report['energy_method'],
            'counter_consistency': [item['counter_consistency_pass'] for item in report['trials']],
        }
write_json(root / 'gpu_energy_audit_20261020.json', {
    'status': 'pass_available_trace_audit', 'completed': len(results), 'planned': 10,
    'boundary': 'shared gross board-power integral; not exclusive per-process energy',
    'results': results,
})
print(json.dumps({'completed': len(results), 'values_uj': {
    key: value['median_gross_uj_per_sdpa'] for key, value in results.items()}}))
