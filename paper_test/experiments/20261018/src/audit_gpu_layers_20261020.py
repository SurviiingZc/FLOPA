"""Audit all accepted full-layer GPU timings and preserve a concise source manifest."""

import json
import statistics
from pathlib import Path

from capture_trajectories import sha, write_json


root = Path('/10T/zhangcheng/flopa_evaluation_20261018')
reports = {}
for model, count, heads, dim in [('pixart', 28, 16, 72), ('wan', 30, 12, 128)]:
    for n in (1024, 4096):
        suffix = '' if n == 1024 else f'_n{n}'
        path = root / 'baselines/layerstep_gpu' / f'{model}{suffix}.json'
        report = json.loads(path.read_text())
        assert report['status'] == 'pass_timing_only'
        assert (report['n'], report['layers'], report['heads'], report['d']) == (
            n, count, heads, dim)
        assert report['step_index'] == 15 and report['branch'] == 'conditional'
        assert report['backend'] == 'FLASH_ATTENTION' and report['dtype'] == 'FP16'
        assert len(report['samples_ms']) == 3
        assert all(len(batch) == 30 for batch in report['samples_ms'])
        values = [sample for batch in report['samples_ms'] for sample in batch]
        assert abs(statistics.median(values) - report['median_ms']) < 1e-12
        assert report['actual_operator_trace']['aten::_scaled_dot_product_flash_attention'] == count
        assert len(report['sources']) == count
        assert {item['layer'] for item in report['sources']} == set(range(count))
        assert report['maximum_capture_output_disagreement'] <= 0.005
        for source in report['sources']:
            assert sha(source['file']) == source['sha256']
        reports[f'{model}_n{n}'] = {
            'status': 'pass_source_audit', 'report': report, 'source': str(path),
            'source_sha256': sha(path), 'audit_scope': 'all source SHA, shapes, traces, 90 samples',
        }
destination = root / 'gpu_layer_audit_20261020.json'
write_json(destination, {'status': 'pass_source_audit', 'results': reports})
print(json.dumps({key: value['report']['median_ms'] for key, value in reports.items()}))
