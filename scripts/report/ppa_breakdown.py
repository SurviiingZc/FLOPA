#!/usr/bin/env python3
"""Extract auditable DC area and Vivado hierarchy data."""
from __future__ import print_function
import argparse
import json
import os
import re


def read_area(path):
    entries = []
    pattern = re.compile(r"^([^ ]+)\s+([0-9.]+)\s+\([ ]*([0-9.]+)%\)")
    with open(path) as handle:
        for line in handle:
            match = pattern.match(line.strip())
            if match:
                entries.append({"instance": match.group(1),
                                "area": float(match.group(2)),
                                "percent": float(match.group(3))})
                continue
            fields = line.strip().split()
            if len(fields) >= 3 and (fields[0].startswith("u_") or
                                     fields[0].startswith("attention_accel_top")):
                try:
                    area = float(fields[1])
                    percent = float(fields[2].strip("()%"))
                    entries.append({"instance": fields[0], "area": area,
                                    "percent": percent})
                except ValueError:
                    pass
    return entries


def read_power(path):
    values = {}
    wanted = ("memory", "clock_network", "register", "combinational", "Total")
    with open(path) as handle:
        for line in handle:
            match = re.match(r"^([^ ]+)\s+([0-9.e+-]+)\s+([0-9.e+-]+)\s+"
                             r"([0-9.e+-]+)\s+([0-9.e+-]+)", line.strip())
            if match and match.group(1) in wanted:
                values[match.group(1)] = {
                    "internal": match.group(2), "switching": match.group(3),
                    "leakage": match.group(4), "total": match.group(5)}
    return values


def read_vivado(path):
    entries = []
    with open(path) as handle:
        for line in handle:
            if not line.startswith("|"):
                continue
            fields = [item.strip() for item in line.strip().strip("|").split("|")]
            if len(fields) < 11 or not fields[2].isdigit():
                continue
            entries.append({"instance": fields[0], "module": fields[1],
                            "lut": int(fields[2]), "ff": int(fields[6]),
                            "uram": int(fields[9]), "dsp": int(fields[10])})
    return entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--out", default="docs/results/ppa_breakdown.json")
    args = parser.parse_args()
    root = os.path.abspath(args.root)
    paths = {
        "dc_area": os.path.join(root, "asic/dc/work/synth/tt/system/attention_accel_top/"
                                 "reports/area.rpt"),
        "dc_vectorless_power": os.path.join(
            root, "asic/dc/work/synth/tt/system/attention_accel_top/reports/power.rpt"),
        "vivado_utilization": os.path.join(root, "fpga/vivado/build/reports/"
                                            "post_route_utilization.rpt")}
    result = {"sources": paths,
              "dc_area": read_area(paths["dc_area"]) if os.path.isfile(paths["dc_area"]) else [],
              "dc_vectorless_power": read_power(paths["dc_vectorless_power"])
              if os.path.isfile(paths["dc_vectorless_power"]) else {},
              "vivado_hierarchy": read_vivado(paths["vivado_utilization"])
              if os.path.isfile(paths["vivado_utilization"]) else []}
    output = os.path.join(root, args.out)
    directory = os.path.dirname(output)
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    with open(output, "w") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    print("DC area entries=%d, Vivado hierarchy entries=%d" %
          (len(result["dc_area"]), len(result["vivado_hierarchy"])))
    print("report=%s" % output)


if __name__ == "__main__":
    main()
