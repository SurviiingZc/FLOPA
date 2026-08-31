#!/usr/bin/env python3
"""Scan the implemented eight-segment PWL exp against mathematical exp."""
from __future__ import print_function
import argparse
import json
import math
import os


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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", default="docs/results/pwl_error.json")
    args = parser.parse_args()
    errors = []
    per_segment = {}
    for x in range(-2048, 1):
        expected = math.exp(float(x) / 256.0) * 32767.0
        error = float(pwl_exp(x)) - expected
        errors.append(error)
        segment = min(7, (-x) >> 8) if x < 0 else 0
        per_segment.setdefault(str(segment), []).append(error)
    result = {
        "domain": [-8.0, 0.0], "q_format": "Q1.15", "segments": 8,
        "sample_count": len(errors), "max_abs_lsb": max(abs(x) for x in errors),
        "rmse_lsb": math.sqrt(sum(x * x for x in errors) / len(errors)),
        "max_abs_relative": max(abs(x) / max(1.0, abs(math.exp(float(i) / 256.0) * 32767.0))
                               for i, x in zip(range(-2048, 1), errors)),
        "per_segment_max_abs_lsb": {
            key: max(abs(x) for x in values) for key, values in per_segment.items()
        }, "implementation": "rtl/softmax/pwl_exp_unit.v"
    }
    directory = os.path.dirname(args.out)
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    with open(args.out, "w") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    print("PWL max_abs_lsb=%.6f rmse_lsb=%.6f max_relative=%.6f" %
          (result["max_abs_lsb"], result["rmse_lsb"], result["max_abs_relative"]))
    print("report=%s" % args.out)


if __name__ == "__main__":
    main()
