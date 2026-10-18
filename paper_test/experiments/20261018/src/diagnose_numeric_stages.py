"""Separate failed-gate numerical stages; never changes scales or acceptance limits."""

import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as functional

from capture_trajectories import sha, write_json
from fixed_point_shadow import reciprocal, shadow
from qualify_captures import metrics


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
VECTOR = ROOT / 'pixart/evaluation_p512_seed301/l14_s15.pt'
torch.set_num_threads(8)
torch.set_grad_enabled(False)
payload = torch.load(VECTOR, map_location='cpu', weights_only=True)
frozen = json.loads((ROOT / 'pixart/frozen_scales.json').read_text())
scale = frozen['scales']['14']
integer = {}
for name in ('q', 'k', 'v'):
    value = payload[name].float().numpy() / scale[name]
    integer[name] = np.clip(np.sign(value) * np.floor(np.abs(value) + 0.5), -127, 127)
    integer[name] = integer[name].astype(np.int8)
reports = []
for head in range(16):
    originals = [payload[name][:, head:head + 1].float() for name in ('q', 'k', 'v')]
    original_output = functional.scaled_dot_product_attention(*originals)[0, 0].numpy()
    inputs = [integer[name][0, head] for name in ('q', 'k', 'v')]
    dequant = [torch.tensor(value.astype(np.float32) * scale[name])[None, None]
               for value, name in zip(inputs, ('q', 'k', 'v'))]
    quantized_output = functional.scaled_dot_product_attention(*dequant)[0, 0].numpy()
    codes, stats, accumulator, denominator = shadow(
        *inputs, scale['score']['register'], scale['out']['register'], return_state=True,
    )
    exact_division = accumulator.astype(np.float64) * scale['v'] / denominator[:, None]
    normalized = (accumulator * reciprocal(denominator)[:, None]) >> 15
    reciprocal_output = normalized.astype(np.float64) * scale['v'] / 32768
    requant_input = normalized.astype(np.float64) * scale['out']['actual'] * scale['o']
    final = codes.astype(np.float64) * scale['o']
    report = {
        'head': head, 'overflow': stats['pv_overflow_events'],
        'input_quantization_vs_original': metrics(quantized_output, original_output),
        'online_fixed_point_exact_division_vs_quantized_sdpa':
            metrics(exact_division, quantized_output),
        'reciprocal_stage_vs_exact_division': metrics(reciprocal_output, exact_division),
        'output_requantization_vs_unrounded': metrics(final, requant_input),
        'exact_division_total_error': metrics(exact_division, original_output),
        'final_total_error': metrics(final, original_output),
        'floating_sdpa_quantized_to_same_output_scale': metrics(
            np.clip(np.sign(original_output) * np.floor(
                np.abs(original_output) / scale['o'] + 0.5), -128, 127) * scale['o'],
            original_output),
    }
    reports.append(report)
    print(head, {key: round(value['relative_l2'], 6) for key, value in report.items()
                 if isinstance(value, dict)}, flush=True)
write_json(ROOT / 'pixart/numerical_stage_diagnosis.json', {
    'role': 'diagnosis of failed qualification; no new accepted design',
    'vector_sha256': sha(VECTOR), 'frozen_scales': scale, 'heads': reports,
    'limits_unchanged': frozen['limits'],
    'note': 'Stage relative errors use their own references and are not additive.',
})
