"""Validate public-interface pilot output and SAIF duration before power readback."""

import csv
import hashlib
import json
import re
from pathlib import Path


ROOT = Path('/data/workspaces/zhangcheng/flash_attention')
RUN = ROOT / 'paper_test/experiments/20261018'
BASE = RUN / 'results/gate_pilot_d72_n32'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    log = BASE.with_suffix('.log').read_text(errors='replace')
    assert '[PASS] tb_paper_replay' in log
    assert 'BYTE_MISMATCH' not in log and 'Fatal:' not in log
    row = next(csv.DictReader(BASE.with_suffix('.csv').open()))
    assert row['status'] == 'pass'
    expected = (RUN / 'replay_smoke/d72_q32_kv32_h1/o.bin').read_bytes()
    observed = Path(str(BASE) + '.csv.observed.bin').read_bytes()
    assert expected == observed
    header = BASE.with_suffix('.saif').open().read(4096)
    time_match = re.search(r'\(TIMESCALE\s+([\d.eE+-]+)\s+(\w+)\)', header)
    duration = re.search(r'\(DURATION\s+([\d.eE+-]+)\)', header)
    assert time_match and duration, header
    unit_ns = {'ps': 0.001, 'ns': 1.0, 'us': 1000.0}[time_match.group(2)]
    resolution_ns = float(time_match.group(1)) * unit_ns
    active_ns = float(duration.group(1)) * resolution_ns
    cycle_ns = int(row['cycles']) * 1.6
    assert abs(active_ns - cycle_ns) <= resolution_ns + 1e-9, (active_ns, cycle_ns)
    mapped = ROOT / 'asic/dc/work/synth/tt/diffusion_runtime_d/attention_accel_top/results'
    report = {
        'status': 'pass_gate_flow_pilot', 'publication_result': False,
        'input_role': 'deterministic synthetic testbench qualification',
        'cycles': int(row['cycles']), 'clock_period_ns': 1.6,
        'saif_active_ns': active_ns, 'cycles_active_ns': cycle_ns,
        'saif_time_resolution_ns': resolution_ns,
        'saif_window_difference_ns': active_ns - cycle_ns,
        'output_bytes': len(observed), 'output_sha256': digest(
            Path(str(BASE) + '.csv.observed.bin')),
        'saif_sha256': digest(BASE.with_suffix('.saif')),
        'mapped_netlist_sha256': digest(mapped / 'attention_accel_top_mapped.v'),
        'mapped_ddc_sha256': digest(mapped / 'attention_accel_top.ddc'),
        'limitations': ['not a real model vector', 'no SDF or physical signoff',
                        'power must not be used in paper model result rows'],
    }
    BASE.with_suffix('.json').write_text(json.dumps(report, indent=4) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
