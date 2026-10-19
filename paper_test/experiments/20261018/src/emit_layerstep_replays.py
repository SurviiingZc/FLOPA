"""Emit verified complete-layer vectors and GPU aggregate reports."""

import json
from pathlib import Path


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
points = []
gpu = {}
for n in (1024, 4096):
    for model, count, pixels in [('pixart', 28, (512, 1024)), ('wan', 30, (256, 512))]:
        pixel = pixels[0 if n == 1024 else 1]
        suffix = '' if n == 1024 else f'_n{n}'
        report = ROOT / 'baselines/layerstep_gpu' / f'{model}{suffix}.json'
        if report.exists():
            gpu[f'{model}_n{n}'] = json.loads(report.read_text())
        for layer in range(count):
            folder = ROOT / 'qualification' / model / f'layerstep_p{pixel}_seed301' / (
                f'l{layer:02d}_s15/full')
            manifest = folder / 'replay_manifest.json'
            if not manifest.exists():
                continue
            record = json.loads(manifest.read_text())
            assert record['nq'] == record['nkv'] == n
            points.append({'name': f'{model}_n{n}_l{layer:02d}_s15', 'model': model,
                           'n': n, 'layer': layer, 'directory': str(folder),
                           'manifest': record})
print(json.dumps({'points': points, 'gpu': gpu}))
