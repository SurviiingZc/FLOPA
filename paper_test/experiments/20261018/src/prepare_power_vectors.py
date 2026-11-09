"""Independent sliced-context calibration for the real-input N256 power job."""

import argparse
import math
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as functional

from capture_trajectories import MODELS, sha, write_json
from fixed_point_shadow import encode_multiplier, shadow
from qualify_captures import metrics


def load_slice(path):
    vector = torch.load(path, map_location='cpu', weights_only=True)
    tensors = [vector[name][:, :1, :256].float() for name in ('q', 'k', 'v')]
    answer = functional.scaled_dot_product_attention(*tensors)
    return tensors, answer


def prepare(root, model):
    config = MODELS[model]
    pixel = 1024 if model == 'pixart' else 512
    filename = f"l{config['layers'][1]:02d}_s15.pt"
    calibration = [root / model / f'power_calibration_p{pixel}_seed{seed}' / filename
                   for seed in (1001, 1002)]
    source = root / model / f'evaluation_p{pixel}_seed301' / filename
    required = [*calibration, source]
    if not all(path.exists() and (path.parent / 'complete.json').exists()
               for path in required):
        return False
    target = root / 'power_vectors' / f'{model}_n256_s301'
    if (target / 'replay_manifest.json').exists():
        return True
    scales = {name: 0.0 for name in ('q', 'k', 'v', 'o')}
    for path in calibration:
        tensors, answer = load_slice(path)
        for name, tensor in zip(scales, [*tensors, answer]):
            scales[name] = max(scales[name], float(tensor.abs().max()) / 127)
    scales = {name: max(value, 1e-12) for name, value in scales.items()}
    score = encode_multiplier(256 * scales['q'] * scales['k'] / math.sqrt(config['dim']))
    out = encode_multiplier(scales['v'] / (32768 * scales['o']))
    tensors, reference = load_slice(source)
    integers = []
    clipping = {}
    for name, tensor in zip(('q', 'k', 'v'), tensors):
        raw = tensor.numpy()[0, 0] / scales[name]
        quantized = np.sign(raw) * np.floor(np.abs(raw) + 0.5)
        clipping[name] = int((np.abs(quantized) > 127).sum())
        integers.append(np.clip(quantized, -127, 127).astype(np.int8))
    answer, statistics = shadow(*integers, score['register'], out['register'])
    target.mkdir(parents=True, exist_ok=True)
    for name, tensor in zip(('q', 'k', 'v', 'o'), [*integers, answer]):
        tensor.tofile(target / (name + '.bin'))
    diagnostic = metrics(answer.astype(np.float32) * scales['o'], reference.numpy()[0, 0])
    write_json(target / 'qualification.json', {
        'status': 'diagnostic_only', 'precision_gate_is_diagnostic': True,
        'source_vector_sha256': sha(source),
        'calibration_sources': {str(path): sha(path) for path in calibration},
        'slice': 'head 0, first 256 Q/K/V rows of native N4096 trajectory',
        'calibration_output': 'FP32 SDPA recomputed on the same sliced context',
        'scales': scales, 'score_encoding': score, 'out_encoding': out,
        'input_clipping_counts': clipping, 'integer': statistics, 'error': diagnostic,
        'shadow_sha256': sha(Path(__file__).with_name('fixed_point_shadow.py')),
    })
    write_json(target / 'replay_manifest.json', {
        'model': model, 'heads': 1, 'nq': 256, 'nkv': 256, 'd': config['dim'],
        'score_scale': score['register'], 'out_scale': out['register'],
        'precision_gate_is_diagnostic': True, 'accuracy_pass': None,
        'accuracy_status': 'deferred; see diagnostic metrics, not a qualification claim',
        'qualification_sha256': sha(target / 'qualification.json'),
        'files_sha256': {name: sha(target / name)
                         for name in ('q.bin', 'k.bin', 'v.bin', 'o.bin')},
    })
    print('POWER_VECTOR_READY', str(target), diagnostic, flush=True)
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    torch.set_num_threads(4)
    torch.set_grad_enabled(False)
    pending = set(MODELS)
    for _ in range(48 * 60 * 2):
        for model in sorted(pending):
            if prepare(args.output, model):
                pending.remove(model)
        if not pending:
            return
        time.sleep(30)
    raise RuntimeError('Power vector preparation exceeded 48 hours')


if __name__ == '__main__':
    main()
