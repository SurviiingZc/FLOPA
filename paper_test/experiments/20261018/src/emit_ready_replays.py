"""Emit only full-query, primary-seed, mid-layer native vectors for RTL replay."""

import hashlib
import json
from pathlib import Path


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
points = []
for model, pixels, layer in [('pixart', [512, 768, 1024, 1536, 2048], 14),
                             ('wan', [256, 384, 512, 768, 1024], 15)]:
    for pixel in pixels:
        folder = ROOT / 'qualification' / model / (
            f'evaluation_p{pixel}_seed301') / f'l{layer:02d}_s15' / 'full'
        manifest = folder / 'replay_manifest.json'
        if not manifest.exists():
            continue
        qualification = json.loads((folder / 'qualification.json').read_text())
        if (qualification['status'] != 'pass_full_shadow' and
                not qualification.get('precision_gate_is_diagnostic', False)):
            continue
        record = json.loads(manifest.read_text())
        points.append({'model': model, 'directory': str(folder), 'manifest': record,
                       'manifest_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest()})
print(json.dumps({'points': points, 'failed_models': [], 'numerical_diagnostics': [
    model for model in ('pixart', 'wan')
    if (ROOT / model / 'numerical_gate_failed.json').exists()
]}))
