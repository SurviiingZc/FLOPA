"""Audit completed evidence and retain an explicit distinction from paper results."""

import csv
import hashlib
import json
import re
import time
from pathlib import Path


ROOT = Path('/data/workspaces/zhangcheng/flash_attention/paper_test/experiments/20261018')
reports = ROOT / 'pilot_power_exact_reports'
coverage = (reports / 'saif_coverage.rpt').read_text()
assert not re.search(r'Warning:.*\(PWR-(18|19)\)', coverage)
for category in ('Nets', 'Ports', 'Pins'):
    assert re.search(category + r'\s+\d+\(100\.00%\)', coverage), category
config = dict(line.split('=', 1) for line in (reports / 'run_config.rpt').read_text().splitlines())
assert config['sram_macros'] == '480'
pilot = json.loads((ROOT / 'results/gate_pilot_d72_n32.json').read_text())
assert pilot['status'] == 'pass_gate_flow_pilot'
power_report = {
    'status': 'pass_flow_qualification_only', 'publication_result': False,
    'user_annotation_percent': {'nets': 100.0, 'ports': 100.0, 'pins': 100.0},
    'annotation_conflicts': 0, 'sram_macros': 480,
    'saif_name_policy': config['saif_name_policy'],
    'saif_window_ns': pilot['saif_active_ns'], 'cycles': pilot['cycles'],
    'ddc_sha256': config['FA_DDC_SHA256'], 'saif_sha256': config['FA_SAIF_SHA256'],
    'reports_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                       for path in reports.glob('*.rpt')},
}
(ROOT / 'results/pilot_power_flow_audit.json').write_text(
    json.dumps(power_report, indent=4) + '\n')
summary = {'timestamp_unix': time.time(), 'stage': 'D1_numerical_gate_failed',
           'rtl_modified': False, 'new_synthesis_performed': False, 'models': {},
           'native_asic_performance_released': False}
for model in ('pixart', 'wan'):
    gate = json.loads((ROOT / f'results/{model}_n1024_gate.json').read_text())
    candidate = json.loads((ROOT / f'results/{model}_counterfactuals.json').read_text())
    items = candidate['variants']['32_segment_probability_and_alpha']
    candidate_errors = [item['candidate_256_seed_retained_exponent_final_error']
                        for item in items]
    summary['models'][model] = {
        'status': gate['status'], 'shape': gate['metadata']['shape'],
        'failed_heads': [item['head'] for item in gate['heads'] if not item['passes']],
        'max_relative_l2': max(item['total_error']['relative_l2'] for item in gate['heads']),
        'min_cosine': min(item['total_error']['cosine'] for item in gate['heads']),
        'pv_overflows': sum(item['integer']['pv_overflow_events'] for item in gate['heads']),
        'input_clipping': gate['input_clipping_counts'],
        'output_saturations': sum(item['integer']['output_saturations']
                                  for item in gate['heads']),
        'candidate_software_only': True,
        'candidate_max_relative_l2': max(item['relative_l2'] for item in candidate_errors),
        'candidate_min_cosine': min(item['cosine'] for item in candidate_errors),
    }
summary['replay_smoke'] = []
for dim in (64, 72, 128):
    row = next(csv.DictReader((ROOT / f'results/replay_smoke_d{dim}.csv').open()))
    assert row['status'] == 'pass'
    summary['replay_smoke'].append(row)
summary['source_files_sha256'] = {
    str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted((ROOT / 'src').glob('*')) if path.is_file()
}
(ROOT / 'results/execution_summary.json').write_text(json.dumps(summary, indent=4) + '\n')
print(json.dumps({model: values['failed_heads'] for model, values in summary['models'].items()}))
