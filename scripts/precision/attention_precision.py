#!/usr/bin/env python3
"""Deterministic 64x64 FP32 versus FLOPA fixed-point attention check."""
from __future__ import print_function

import argparse
import json
import math
import os


def lcg(seed):
    value = seed & 0xffffffff
    while True:
        value = (1664525 * value + 1013904223) & 0xffffffff
        yield ((value >> 24) & 0xff) - 128


def tensor(seed, rows, dim):
    gen = lcg(seed)
    return [[next(gen) for _ in range(dim)] for _ in range(rows)]


def softmax(values):
    peak = max(values)
    weights = [math.exp(value - peak) for value in values]
    total = sum(weights)
    return [value / total for value in weights]


def fp_attention(q, k, v, causal):
    rows = len(q)
    dim = len(q[0])
    scale = 1.0 / math.sqrt(float(dim))
    result = []
    for row in range(rows):
        scores = []
        for col in range(rows):
            if causal and col > row:
                scores.append(float("-inf"))
            else:
                dot = sum(q[row][d] * k[col][d] for d in range(dim))
                scores.append(dot * scale)
        weights = softmax(scores)
        result.append([sum(weights[col] * v[col][d] for col in range(rows))
                       for d in range(dim)])
    return result


def pwl_exp(x):
    if x >= 0:
        return 32767
    if x <= -2048:
        return 0
    magnitude = -x
    segment = min(7, magnitude >> 8)
    fraction = magnitude & 0xff
    points = ((32767, 12055), (12055, 4435), (4435, 1632),
              (1632, 600), (600, 221), (221, 81), (81, 30), (30, 11))
    low, high = points[segment]
    return max(0, min(32767, low - ((low - high) * fraction >> 8)))


def score_scale_exact(score, mantissa, shift):
    product = score * mantissa
    shifted = product >> shift if shift else product
    if shifted > 65535:
        shifted = 65535
    elif shifted < -65536:
        shifted = -65536
    if shift:
        guard = (product >> (shift - 1)) & 1
        sticky = 1 if (product & ((1 << (shift - 1)) - 1)) else 0
        if guard and (product >= 0 or sticky):
            shifted += 1
    return max(-32768, min(32767, shifted))


def reciprocal_lut(value):
    if value == 0:
        return 0
    msb = value.bit_length() - 1
    normalized = value >> (msb - 15) if msb >= 15 else value << (15 - msb)
    seeds = (32767, 30840, 29127, 27594, 26214, 24966, 23831, 22795,
             21845, 20972, 20165, 19418, 18725, 18079, 17476, 16913)
    seed = seeds[(normalized >> 11) & 0xf]
    return seed >> (msb - 15) if msb > 15 else seed << (15 - msb)


def fixed_attention(q, k, v, score_mantissa, score_shift, out_mantissa,
                    out_shift, causal):
    rows = len(q)
    dim = len(q[0])
    result = []
    for row in range(rows):
        old_m = 0
        old_l = 0
        old_o = [0 for _ in range(dim)]
        state_valid = False
        for block_start in range(0, rows, 32):
            block_end = min(rows, block_start + 32)
            scores = []
            for col in range(block_start, block_end):
                valid = (not causal) or (col <= row)
                dot = sum(q[row][d] * k[col][d] for d in range(dim))
                scores.append(dot if valid else -2147483648)
            valid_scores = [score for score in scores if score != -2147483648]
            if not valid_scores:
                continue
            block_max = max(valid_scores)
            new_m = max(old_m, block_max) if state_valid else block_max
            alpha = (pwl_exp(score_scale_exact(old_m - new_m,
                                                score_mantissa, score_shift))
                     if state_valid else 0)
            probs = []
            for score in scores:
                probs.append(0 if score == -2147483648 else
                             pwl_exp(score_scale_exact(score - new_m,
                                                        score_mantissa, score_shift)))
            block_sum = sum(probs)
            old_l = ((old_l * alpha) >> 15) + block_sum
            for feature in range(dim):
                value = ((old_o[feature] * alpha) >> 15) if state_valid else 0
                for offset, col in enumerate(range(block_start, block_end)):
                    value += probs[offset] * v[col][feature]
                old_o[feature] = value
            old_m = new_m
            state_valid = True
        reciprocal = reciprocal_lut(old_l)
        row_out = []
        for feature in range(dim):
            normalized = (old_o[feature] * reciprocal) >> 15 if old_l else 0
            scaled = (normalized * out_mantissa) >> out_shift
            row_out.append(max(-128, min(127, scaled)))
        result.append(row_out)
    return result


def encode(mantissa, shift):
    return ((shift & 0x3f) << 16) | (mantissa & 0xffff)


def metrics(reference, candidate):
    errors = [candidate[r][d] - reference[r][d]
              for r in range(len(reference)) for d in range(len(reference[0]))]
    mae = sum(abs(value) for value in errors) / float(len(errors))
    rmse = math.sqrt(sum(value * value for value in errors) / float(len(errors)))
    ref_norm = math.sqrt(sum(value * value for row in reference for value in row))
    cand_norm = math.sqrt(sum(value * value for row in candidate for value in row))
    dot = sum(reference[r][d] * candidate[r][d]
              for r in range(len(reference)) for d in range(len(reference[0])))
    cosine = dot / (ref_norm * cand_norm) if ref_norm and cand_norm else 0.0
    return {"mae": mae, "rmse": rmse, "max_abs": max(abs(value) for value in errors),
            "cosine": cosine}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seed", type=int, default=301)
    parser.add_argument("--rows", type=int, default=64)
    parser.add_argument("--dim", type=int, default=64)
    parser.add_argument("--out", default="docs/results/precision_64x64.json")
    args = parser.parse_args()
    q = tensor(args.seed, args.rows, args.dim)
    k = tensor(args.seed + 1, args.rows, args.dim)
    v = tensor(args.seed + 2, args.rows, args.dim)
    results = []
    for causal in (False, True):
        reference = fp_attention(q, k, v, causal)
        best = None
        for score_ratio in (1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0):
            score_shift = 8
            score_mantissa = int(round(score_ratio * (1 << score_shift)))
            for out_ratio in (1.0 / 65536.0, 1.0 / 32768.0, 1.0 / 16384.0,
                              1.0 / 8192.0, 1.0 / 4096.0, 1.0 / 2048.0):
                out_shift = 15
                out_mantissa = max(1, int(round(out_ratio * (1 << out_shift))))
                candidate = fixed_attention(q, k, v, score_mantissa, score_shift,
                                            out_mantissa, out_shift, causal)
                item = metrics(reference, candidate)
                item.update({"causal": causal, "score_mantissa": score_mantissa,
                             "score_shift": score_shift, "out_mantissa": out_mantissa,
                             "out_shift": out_shift,
                             "score_scale": "0x%08x" % encode(score_mantissa, score_shift),
                             "out_scale": "0x%08x" % encode(out_mantissa, out_shift)})
                if best is None or item["rmse"] < best["rmse"]:
                    best = item
        results.append(best)
    report = {"shape": [args.rows, args.rows, args.dim], "seed": args.seed,
              "reference_backend": "python-ieee754-fallback",
              "numeric_contract": "INT8 Q/K/V, Q1.15 P, INT32 state, PWL exp",
              "results": results}
    directory = os.path.dirname(args.out)
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    for item in results:
        print("causal=%s score=%s out=%s MAE=%.6f RMSE=%.6f max=%d cosine=%.6f" %
              (item["causal"], item["score_scale"], item["out_scale"], item["mae"],
               item["rmse"], item["max_abs"], item["cosine"]))
    print("report=%s" % args.out)


if __name__ == "__main__":
    main()
