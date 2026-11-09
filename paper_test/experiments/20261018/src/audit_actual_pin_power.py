"""Validate same-DDC/SAIF power rereads using actual library pin loads."""

import argparse
import csv
import fcntl
import json
import re
from pathlib import Path

from collect_publication_data import digest, load


ROOT = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
RUN = ROOT / 'experiments/20261018'
parser = argparse.ArgumentParser()
parser.add_argument('--publish', action='store_true')
args = parser.parse_args()
names = ['power_pixart_n256_s301', 'power_wan_n256_s301', 'power_f2_pixart_n256_s301']
results = {}
for name in names:
    folder = RUN / 'jobs' / name
    directory = folder / 'power_reports_actual_pin_load'
    status = load(folder / 'status.json')
    assert status['state'] == 'pass' and status['functional_byte_exact_pass']
    config_path = directory / 'run_config.rpt'
    if not config_path.exists():
        print(json.dumps({'state': 'readback_running', 'waiting_for': name}))
        raise SystemExit(3)
    config = dict(line.split('=', 1) for line in config_path.read_text().splitlines()
                  if '=' in line)
    assert config['high_fanout_net_threshold'] == '0'
    assert digest(Path(config['FA_DDC_FILE'])) == config['FA_DDC_SHA256']
    assert digest(folder / 'activity.saif') == config['FA_SAIF_SHA256'] == status['saif_sha256']
    assert digest(folder / 'result.csv.observed.bin') == status['manifest']['files_sha256']['o.bin']
    row = next(csv.DictReader((folder / 'result.csv').open()))
    assert row['status'] == 'pass' and int(row['cycles']) == status['cycles']
    coverage = (directory / 'saif_coverage.rpt').read_text()
    for category in ('Nets', 'Ports', 'Pins'):
        assert re.search(r'\b' + category + r'\s+\d+\(100\.00%\)', coverage)
    console = (folder / 'power_work_actual_pin_load/console.log').read_text()
    assert not re.search(r'\(PWR-18\)|\(PWR-19\)|^\s*Error:', console, re.M)
    text = (directory / 'power_summary.rpt').read_text()
    values = {}
    for key, label in [('dynamic_w', 'Total Dynamic Power'), ('leakage_w', 'Cell Leakage Power')]:
        match = re.search(label + r'\s*=\s*([\d.eE+-]+)\s*(mW|nW|uW|W)', text)
        assert match
        values[key] = float(match[1]) * {'W': 1, 'mW': 1e-3, 'uW': 1e-6, 'nW': 1e-9}[match[2]]
    values['total_w'] = values['dynamic_w'] + values['leakage_w']
    seconds = status['saif_active_ns'] * 1e-9
    macs = 2 * 256 * 256 * status['manifest']['d']
    values.update(energy_job_j=values['total_w'] * seconds,
                  pj_per_mac=values['total_w'] * seconds / macs * 1e12,
                  effective_tops=2 * macs / seconds / 1e12)
    match = re.search(r'clock_network[^\n]*\(\s*([\d.]+)%\)', text)
    results[name] = {
        'activity_based_estimate': values,
        'legacy_estimate': status.get('legacy_high_fanout_activity_estimate',
                                      status['activity_based_estimate']),
        'power_report_directory': 'power_reports_actual_pin_load',
        'load_model': ('actual library pin loads; high_fanout_net_threshold=0; '
                       'ZeroWireload; pre-CTS'),
        'power_summary_sha256': digest(directory / 'power_summary.rpt'),
        'clock_network_percent': float(match[1]) if match else None,
        'ddc_sha256': config['FA_DDC_SHA256'], 'saif_sha256': status['saif_sha256'],
    }
f0 = results[names[0]]['activity_based_estimate']
f2 = results[names[2]]['activity_based_estimate']
comparison = load(RUN / 'results/f2_comparison.json')
comparison.update(f0_energy_uj=f0['energy_job_j'] * 1e6,
                  f2_energy_uj=f2['energy_job_j'] * 1e6,
                  energy_reduction_fraction=1 - f0['energy_job_j'] / f2['energy_job_j'],
                  scope='N256/H1/d72/seed301, actual library pin loads, pre-layout IP',
                  load_model='high_fanout_net_threshold=0; no synthesis or RTL change')
output = {'status': 'pass_actual_pin_load_audit', 'results': results, 'f2_comparison': comparison}
if args.publish:
    lock = (RUN / 'publication_update.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX)
    for name, result in results.items():
        path = RUN / 'jobs' / name / 'status.json'
        status = load(path)
        status.setdefault('legacy_high_fanout_activity_estimate', status['activity_based_estimate'])
        status.update({key: value for key, value in result.items() if key != 'legacy_estimate'})
        temporary = path.with_suffix('.power_update.tmp')
        temporary.write_text(json.dumps(status, indent=4) + '\n')
        temporary.replace(path)
    (RUN / 'results/f2_comparison.json').write_text(json.dumps(comparison, indent=4) + '\n')
    manual_path = RUN / 'checklist_manual.json'
    manual = load(manual_path)
    manual['clock_power_audit'] = {
        'done': True, 'status': '已核验1001pF简化负载，三点按实际库pin负载回读；仍为pre-CTS',
        'evidence': str(RUN / 'results/actual_pin_load_power_audit_20261020.json'),
    }
    manual['f2_comparison']['status'] = (
        f"周期降6.73%；实际pin负载IP能量降{comparison['energy_reduction_fraction'] * 100:.2f}%")
    manual_path.write_text(json.dumps(manual, ensure_ascii=False, indent=4) + '\n')
    (RUN / 'results/actual_pin_load_power_audit_20261020.json').write_text(
        json.dumps(output, indent=4) + '\n')
print(json.dumps(output))
