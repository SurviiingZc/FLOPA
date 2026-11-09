"""Export every layer at one real denoising step with independent per-layer scales."""

import json
import argparse
import time
from pathlib import Path

import torch

from capture_trajectories import MODELS, write_json
from qualify_captures import calibration, qualify


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
parser = argparse.ArgumentParser()
parser.add_argument('--n', type=int, choices=[1024, 4096], default=1024)
args = parser.parse_args()
torch.set_num_threads(4)
torch.set_grad_enabled(False)
for model, config in MODELS.items():
    count = 28 if model == 'pixart' else 30
    pixel = config['pixels'][0 if args.n == 1024 else 2]
    point = ROOT / model / f'layerstep_p{pixel}_seed301'
    for _ in range(48 * 60 * 2):
        if (point / 'complete.json').exists():
            break
        time.sleep(30)
    else:
        raise RuntimeError('All-layer capture missing: ' + model)
    baseline = ROOT / model / f'evaluation_p{pixel}_seed301' / (
        f"l{config['layers'][1]:02d}_s15.pt")
    middle = torch.load(point / baseline.name, map_location='cpu', weights_only=True)
    original = torch.load(baseline, map_location='cpu', weights_only=True)
    assert all(torch.equal(middle[name], original[name]) for name in ('q', 'k', 'v'))
    frozen = calibration(ROOT, model)
    for layer in range(count):
        report = qualify(point / f'l{layer:02d}_s15.pt', frozen, ROOT,
                         diagnostic_precision=True)
        print('LAYERSTEP_EXPORTED', model, layer, report['accuracy_pass'], flush=True)
    marker = 'layerstep_export_complete.json' if args.n == 1024 else (
        f'layerstep_n{args.n}_export_complete.json')
    write_json(ROOT / model / marker, {
        'status': 'all_layers_exported', 'layers': count, 'n': args.n,
        'step_index': 15, 'branch': 'conditional', 'middle_qkv_equals_main_vector': True,
        'scope': 'all self-attention layers of one step, not full denoiser latency',
    })
