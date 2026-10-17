"""Extract the current mapped synthesis without mixing historical SAIF power."""

import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
reports = root / 'asic/dc/work/synth/tt/diffusion_runtime_d/attention_accel_top/reports'
validation = json.loads((root / 'paper_test/validation_manifest.json').read_text())


def fields(name):
    return dict(line.split('=', 1) for line in (reports / name).read_text().splitlines()
                if '=' in line)


def match_number(pattern, text):
    found = re.search(pattern, text, re.M)
    assert found, pattern
    return float(found.group(1))


config = fields('run_config.rpt')
timing_status = fields('timing_status.rpt')
assert config['FA_GIT_COMMIT'] == validation['git_commit']
assert config['validation_manifest_sha256'] == hashlib.sha256(
    (root / 'paper_test/validation_manifest.json').read_bytes()
).hexdigest()
assert int(config['validated_max_d']) == 128
assert int(config['sram_macro_count']) == validation['expected_sram_macros']
assert int(config['rtl_icg_count']) == validation['expected_rtl_icgs']
assert config['automatic_clock_gating'] == '0'
area_text = (reports / 'area.rpt').read_text()
power_text = (reports / 'power.rpt').read_text()
timing_text = (reports / 'timing.rpt').read_text()
min_text = (reports / 'timing_min.rpt').read_text()
area = match_number(r'^Total cell area:\s+([\d.]+)', area_text)
macro_area = match_number(r'^Macro/Black Box area:\s+([\d.]+)', area_text)
slacks = re.findall(r'slack \([^)]*\)\s+(-?[\d.]+)', timing_text)
min_slacks = re.findall(r'slack \([^)]*\)\s+(-?[\d.]+)', min_text)
assert slacks and min_slacks
total_power = re.findall(
    r'^Total\s+.*?([\d.eE+-]+)\s+mW\s*$', power_text, re.M
)
assert total_power
result = {
    'git_commit': config['FA_GIT_COMMIT'], 'rtl_sha256': config['FA_RTL_HASH'],
    'validated_max_d': 128, 'clock_period_ns': float(config['clock_period_ns']),
    'target_clock_mhz': 1000 / float(config['clock_period_ns']),
    'area_library_um2': area, 'area_mm2': area / 1e6,
    'sram_area_mm2': macro_area / 1e6,
    'sram_macro_count': int(config['sram_macro_count']),
    'explicit_rtl_icgs': int(config['rtl_icg_count']),
    'dw_multipliers': int(config['linked_dw02_mult_count']),
    'worst_setup_slack_ns': min(map(float, slacks)),
    'worst_hold_slack_ns': min(map(float, min_slacks)),
    'timing_status': timing_status,
    'vectorless_reported_total_mw': float(total_power[-1]),
    'power_boundary': 'DC default vectorless estimate; no new gate-SAIF activity',
    'physical_boundary': 'mapped TT synthesis; no placement, routed RC or CTS signoff',
    'completed_functional_jobs': validation['completed_jobs'],
    'checked_output_bytes': validation['checked_bytes'],
    'report_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                      for path in sorted(reports.glob('*.rpt'))},
    'reports': str(reports.relative_to(root)),
}
destination = root / 'paper_test/synthesis_summary.json'
destination.write_text(json.dumps(result, indent=4) + '\n')
print(json.dumps({key: value for key, value in result.items()
                  if key != 'report_sha256'}, indent=2))
