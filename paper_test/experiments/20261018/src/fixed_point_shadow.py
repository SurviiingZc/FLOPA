"""Integer shadow of committed FLOPA arithmetic; tracks every pre-wrap PV sum."""

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np


EXP = np.array([32767, 12055, 4435, 1632, 600, 221, 81, 30, 11], dtype=np.int64)
RECIP = np.array([
    32767, 30840, 29127, 27594, 26214, 24966, 23831, 22795,
    21845, 20972, 20165, 19418, 18725, 18079, 17476, 16913,
], dtype=np.int64)


def wrap32(value):
    return ((value + (1 << 31)) % (1 << 32)) - (1 << 31)


def rounded_shift(value, shift):
    if shift == 0:
        return value
    remainder = value & ((1 << shift) - 1)
    half = 1 << (shift - 1)
    increment = (remainder > half) | ((remainder == half) & (value >= 0))
    return (value >> shift) + increment


def scale_scores(value, register):
    product = value * (register & 65535)
    shift = (register >> 16) & 63
    base = np.clip(product >> shift, -65536, 65535)
    increment = rounded_shift(product, shift) - (product >> shift)
    return np.clip(base + increment, -32768, 32767)


def pwl(value):
    magnitude = np.clip(-value, 0, 2047)
    segment = magnitude >> 8
    result = EXP[segment] - (((EXP[segment] - EXP[segment + 1]) *
                             (magnitude & 255)) >> 8)
    return np.where(value >= 0, 32767, np.where(value <= -2048, 0, result))


def reciprocal(value):
    msb = np.zeros_like(value)
    for bit in range(32):
        msb = np.where(value >= (1 << bit), bit, msb)
    normalized = np.where(msb >= 15, value >> np.maximum(msb - 15, 0),
                          value << np.maximum(15 - msb, 0))
    seed = RECIP[(normalized >> 11) & 15]
    answer = np.where(msb > 15, seed >> np.maximum(msb - 15, 0),
                      seed << np.maximum(15 - msb, 0))
    return np.where(value == 0, 0, answer)


def encode_multiplier(factor):
    assert factor > 0
    candidates = []
    for shift in range(64):
        mantissa = int(np.floor(factor * (2 ** shift) + 0.5))
        if 1 <= mantissa <= 32767:
            actual = mantissa / (2 ** shift)
            candidates.append((abs(actual / factor - 1), -shift, mantissa, shift))
    assert candidates, factor
    error, _, mantissa, shift = min(candidates)
    return {'register': (shift << 16) | mantissa, 'mantissa': mantissa,
            'shift': shift, 'ideal': factor, 'actual': mantissa / (2 ** shift),
            'relative_encoding_error': error}


def shadow(q, k, v, score_register, out_register, query_indices=None, return_state=False,
           probability_exp=None, alpha_exp=None):
    """One head. All K/V visited; optional query sampling is explicitly reported."""
    original_rows = len(q)
    probability_exp = pwl if probability_exp is None else probability_exp
    alpha_exp = pwl if alpha_exp is None else alpha_exp
    if query_indices is None:
        query_indices = np.arange(len(q))
    q = q[query_indices].astype(np.int64)
    k, v = k.astype(np.int64), v.astype(np.int64)
    output = np.zeros((len(q), v.shape[1]), dtype=np.int8)
    final_acc = np.zeros((len(q), v.shape[1]), dtype=np.int64) if return_state else None
    final_l = np.zeros(len(q), dtype=np.int64) if return_state else None
    stats = {'query_rows': len(q), 'kv_rows': len(k), 'pv_overflow_events': 0,
             'row_sum_saturations': 0, 'p_zero': 0, 'p_total': 0,
             'max_absolute_pre_wrap': 0, 'first_overflow': None,
             'output_saturations': 0, 'full_query_coverage': len(q) == original_rows}
    for row_start in range(0, len(q), 16):
        queries = q[row_start:row_start + 16]
        maximum = None
        denominator = np.zeros(len(queries), dtype=np.int64)
        acc = np.zeros((len(queries), v.shape[1]), dtype=np.int64)
        for col_start in range(0, len(k), 32):
            scores = queries @ k[col_start:col_start + 32].T
            new_max = scores.max(axis=1)
            if maximum is None:
                alpha = np.zeros(len(queries), dtype=np.int64)
            else:
                new_max = np.maximum(maximum, new_max)
                alpha = alpha_exp(scale_scores(maximum - new_max, score_register))
            probability = probability_exp(scale_scores(scores - new_max[:, None], score_register))
            stats['p_zero'] += int((probability == 0).sum())
            stats['p_total'] += probability.size
            raw_l = ((denominator * alpha) >> 15) + probability.sum(axis=1)
            stats['row_sum_saturations'] += int((raw_l > 0xffffffff).sum())
            denominator = np.minimum(raw_l, 0xffffffff)
            seed = (acc * alpha[:, None]) >> 15
            products = probability[:, :, None] * v[None, col_start:col_start + 32, :]
            # Prefixes use modular equivalence to locate the exact PE addition
            # that overflows, even when an earlier PE in this tile already wrapped.
            prefixes = np.cumsum(products, axis=1)
            previous = np.concatenate((seed[:, None, :],
                wrap32(seed[:, None, :] + prefixes[:, :-1, :])), axis=1)
            raw = previous + products
            invalid = (raw < -(1 << 31)) | (raw > (1 << 31) - 1)
            stats['pv_overflow_events'] += int(invalid.sum())
            stats['max_absolute_pre_wrap'] = max(stats['max_absolute_pre_wrap'],
                                               int(np.abs(raw).max()))
            if invalid.any() and stats['first_overflow'] is None:
                row, col, dim = np.argwhere(invalid)[0]
                stats['first_overflow'] = {
                    'query': int(query_indices[row_start + row]),
                    'key': col_start + int(col), 'feature': int(dim),
                    'pre_wrap': int(raw[row, col, dim]),
                }
            acc = wrap32(seed + prefixes[:, -1, :])
            maximum = new_max
        normalized = (acc * reciprocal(denominator)[:, None]) >> 15
        value = rounded_shift(normalized * (out_register & 65535),
                              (out_register >> 16) & 63)
        stats['output_saturations'] += int(((value < -128) | (value > 127)).sum())
        output[row_start:row_start + len(queries)] = np.clip(value, -128, 127)
        if return_state:
            final_acc[row_start:row_start + len(queries)] = acc
            final_l[row_start:row_start + len(queries)] = denominator
    if return_state:
        return output, stats, final_acc, final_l
    return output, stats


def self_test(output):
    cases = []
    for value in (-128, 127):
        for n in (512, 513, 516, 517, 1024, 16384):
            acc = 0
            first = None
            peak = 0
            for token in range(n):
                if token % 32 == 0:
                    acc = (acc * 32767) >> 15
                raw = acc + 32767 * value
                if (raw < -(1 << 31) or raw >= (1 << 31)) and first is None:
                    first = token + 1
                peak = max(peak, abs(raw))
                acc = int(wrap32(np.int64(raw)))
            cases.append({'n': n, 'v': value, 'first_overflow_token': first,
                          'final_wrapped_accumulator': acc, 'max_abs_pre_wrap': peak})
    assert next(x for x in cases if x['n'] == 513 and x['v'] == -128)[
        'first_overflow_token'] == 513
    assert next(x for x in cases if x['n'] == 517 and x['v'] == 127)[
        'first_overflow_token'] == 517
    assert all(x['first_overflow_token'] is None for x in cases if x['n'] == 512)
    report = {'status': 'pass_reproduced_int32_limit', 'source_sha256':
              hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), 'cases': cases,
              'scope': 'adversarial arithmetic check; not real-model qualification'}
    output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--self-test', type=Path, required=True)
    self_test(parser.parse_args().self_test)
