"""Software-only numerical counterfactuals; never represent synthesized hardware."""

import json
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as functional

from capture_trajectories import sha, write_json
from fixed_point_shadow import pwl, rounded_shift, shadow
from qualify_captures import metrics


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
VECTOR = ROOT / 'pixart/evaluation_p512_seed301/l14_s15.pt'
torch.set_grad_enabled(False)
torch.set_num_threads(8)
payload = torch.load(VECTOR, map_location='cpu', weights_only=True)
scale = json.loads((ROOT / 'pixart/frozen_scales.json').read_text())['scales']['14']


def ideal_exp(value):
    answer = np.floor(32767 * np.exp(np.clip(value, -2048, 0) / 256) + 0.5)
    return np.where(value <= -2048, 0, answer).astype(np.int64)


def pwl32(value):
    endpoints = np.floor(32767 * np.exp(-np.arange(33) / 4) + 0.5).astype(np.int64)
    magnitude = np.clip(-value, 0, 2047)
    segment, fraction = magnitude >> 6, magnitude & 63
    result = endpoints[segment] - (((endpoints[segment] - endpoints[segment + 1]) *
                                   fraction) >> 6)
    return np.where(value >= 0, 32767, np.where(value <= -2048, 0, result))


def normalized_with_retained_exponent(accumulator, denominator):
    msb = np.floor(np.log2(np.maximum(denominator, 1))).astype(np.int64)
    normalized_l = np.where(msb >= 15, denominator >> np.maximum(msb - 15, 0),
                            denominator << np.maximum(15 - msb, 0))
    index = (normalized_l - 32768) >> 7
    midpoint = 32768 + 128 * index + 64
    seed = np.floor((1 << 30) / midpoint + 0.5).astype(np.int64)
    return (accumulator * seed[:, None]) >> msb[:, None]


variants = [('ideal_probability_only', ideal_exp, pwl),
            ('ideal_alpha_only', pwl, ideal_exp),
            ('ideal_probability_and_alpha', ideal_exp, ideal_exp),
            ('32_segment_probability_and_alpha', pwl32, pwl32)]
reports = {name: [] for name, _, _ in variants}
for head in range(16):
    qkv = [payload[name][0, head].float().numpy() for name in ('q', 'k', 'v')]
    inputs = []
    for name, value in zip(('q', 'k', 'v'), qkv):
        raw = value / scale[name]
        inputs.append(np.clip(np.sign(raw) * np.floor(np.abs(raw) + 0.5), -127, 127)
                      .astype(np.int8))
    reference = functional.scaled_dot_product_attention(
        *[torch.from_numpy(value)[None, None] for value in qkv])[0, 0].numpy()
    for name, probability_exp, alpha_exp in variants:
        codes, stats, acc, denominator = shadow(
            *inputs, scale['score']['register'], scale['out']['register'],
            return_state=True, probability_exp=probability_exp, alpha_exp=alpha_exp,
        )
        report = {
            'head': head, 'overflow': stats['pv_overflow_events'],
            'exact_division_error': metrics(acc * scale['v'] / denominator[:, None], reference),
            'original_normalizer_final_error': metrics(codes * scale['o'], reference),
        }
        if name == '32_segment_probability_and_alpha':
            normalized = normalized_with_retained_exponent(acc, denominator)
            encoded = rounded_shift(normalized * scale['out']['mantissa'],
                                    scale['out']['shift'])
            candidate = np.clip(encoded, -128, 127) * scale['o']
            report['candidate_256_seed_retained_exponent_final_error'] = metrics(
                candidate, reference)
        reports[name].append(report)
    print('COUNTERFACTUAL_HEAD_COMPLETE', head, flush=True)
write_json(ROOT / 'pixart/software_counterfactuals.json', {
    'role': 'software-only diagnosis; no RTL, synthesis or PPA claims',
    'vector_sha256': sha(VECTOR), 'frozen_scales': scale, 'variants': reports,
    'acceptance_unchanged': {'relative_l2': 0.05, 'cosine': 0.99},
})
