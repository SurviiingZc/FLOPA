"""Verify native results and full-layer aggregates newly completed on 20 October."""

import csv
import json
from pathlib import Path

from collect_publication_data import digest, load


root = Path('/data/workspaces/zhangcheng/flash_attention/paper_test/experiments/20261018')


def replay(name):
    folder = root / 'jobs' / name
    report = load(folder / 'status.json')
    assert report['state'] == 'pass'
    row = next(csv.DictReader((folder / 'result.csv').open()))
    assert row['status'] == 'pass' and int(row['cycles']) == report['cycles']
    manifest = report['manifest']
    assert digest(folder / 'result.csv.observed.bin') == manifest['files_sha256']['o.bin']
    assert '[PASS] tb_paper_replay' in (folder / 'run.log').read_text()
    return report


native = {}
for model, heads, dim in [('pixart', 16, 72), ('wan', 12, 128)]:
    for n in (1024, 2304, 4096):
        name = f'{model}_n{n}'
        report = replay(name)
        manifest = report['manifest']
        assert (manifest['heads'], manifest['nq'], manifest['nkv'], manifest['d']) == (
            heads, n, n, dim)
        native[name] = report
layers = {}
for model, count in [('pixart', 28), ('wan', 30)]:
    report = load(root / 'results' / f'layerstep_{model}.json')
    assert report['status'] == 'pass_all_layers'
    assert set(report['jobs']) == {f'{model}_n1024_l{index:02d}_s15' for index in range(count)}
    assert len(report['jobs']) == count
    actual = [replay(name) for name in report['jobs']]
    assert sum(item['cycles'] for item in actual) == report['cycles']
    assert abs(report['latency_ms'] - report['cycles'] * 1.6e-6) < 1e-9
    layers[model] = report
result = {'status': 'pass_artifact_audit', 'native': native, 'layers': layers}
destination = root / 'results/verified_update_20261020.json'
destination.write_text(json.dumps(result, indent=4) + '\n')
print(json.dumps({'native_points': len(native), 'layers': {
    model: report['latency_ms'] for model, report in layers.items()}}))
