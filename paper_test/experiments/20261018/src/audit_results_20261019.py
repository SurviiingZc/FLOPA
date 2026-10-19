"""Recheck completed artifacts before publishing the new result set."""

import csv
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
RUN = ROOT / 'experiments/20261018'


def load(path):
    return json.loads(path.read_text())


def sha(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(8 << 20), b''):
            result.update(block)
    return result.hexdigest()


def replay(name):
    folder = RUN / 'jobs' / name
    report = load(folder / 'status.json')
    assert report['state'] == 'pass'
    row = next(csv.DictReader((folder / 'result.csv').open()))
    assert row['status'] == 'pass' and int(row['cycles']) == report['cycles']
    assert '[PASS] tb_paper_replay' in (folder / 'run.log').read_text()
    assert sha(folder / 'result.csv.observed.bin') == report['manifest'][
        'files_sha256']['o.bin']
    return report


def power(name):
    report = replay(name)
    folder = RUN / 'jobs' / name
    assert report['functional_byte_exact_pass'] is True
    assert sha(folder / 'activity.saif') == report['saif_sha256']
    with (folder / 'activity.saif').open() as handle:
        header = handle.read(4096)
    unit = re.search(r'\(TIMESCALE\s+([\d.eE+-]+)\s+(\w+)\)', header)
    duration = re.search(r'\(DURATION\s+([\d.eE+-]+)\)', header)
    factor = float(unit[1]) * {'ps': 0.001, 'ns': 1, 'us': 1000}[unit[2]]
    assert abs(float(duration[1]) * factor - report['cycles'] * 1.6) <= factor + 1e-9
    coverage = (folder / 'power_reports/saif_coverage.rpt').read_text()
    for category in ('Nets', 'Ports', 'Pins'):
        assert re.search(r'\b' + category + r'\s+\d+\(100\.00%\)', coverage)
    console = (folder / 'power_work/console.log').read_text()
    assert not re.search(r'\(PWR-18\)|\(PWR-19\)|^\s*Error:', console, re.M)
    config = dict(line.split('=', 1) for line in (
        folder / 'power_reports/run_config.rpt').read_text().splitlines() if '=' in line)
    assert sha(Path(config['FA_DDC_FILE'])) == config['FA_DDC_SHA256']
    assert config['FA_SAIF_SHA256'] == report['saif_sha256']
    values = report['activity_based_estimate']
    energy = values['total_w'] * report['saif_active_ns'] * 1e-9
    assert abs(energy - values['energy_job_j']) < 1e-12
    return report


native = {name: replay(name) for name in (
    'pixart_n1024', 'wan_n1024', 'pixart_n2304', 'wan_n2304')}
powers = {name: power(name) for name in (
    'power_pixart_n256_s301', 'power_wan_n256_s301', 'power_f2_pixart_n256_s301')}
f0 = powers['power_pixart_n256_s301']
f2 = powers['power_f2_pixart_n256_s301']
assert f0['manifest']['files_sha256'] == f2['manifest']['files_sha256']
assert f0['manifest']['qualification_sha256'] == f2['manifest']['qualification_sha256']
layers = load(RUN / 'results/layerstep_pixart.json')
assert layers['status'] == 'pass_all_layers' and len(set(layers['jobs'])) == 28
assert set(layers['jobs']) == {f'pixart_n1024_l{layer:02d}_s15' for layer in range(28)}
actual = [replay(name) for name in layers['jobs']]
assert sum(item['cycles'] for item in actual) == layers['cycles']
comparison = {
    'status': 'pass_matched_gate_evidence', 'f0_cycles': f0['cycles'],
    'f2_cycles': f2['cycles'], 'cycle_reduction_fraction': 1 - f0['cycles'] / f2['cycles'],
    'speedup_f0_over_f2': f2['cycles'] / f0['cycles'],
    'f0_energy_uj': f0['activity_based_estimate']['energy_job_j'] * 1e6,
    'f2_energy_uj': f2['activity_based_estimate']['energy_job_j'] * 1e6,
    'energy_reduction_fraction': 1 - f0['activity_based_estimate']['energy_job_j'] /
        f2['activity_based_estimate']['energy_job_j'],
    'scope': 'N256/H1/d72/seed301 mapped pre-layout IP; pre-CTS clock-load review pending',
    'numerical_precision': 'diagnostic; not FP16-equivalent or closed-loop qualified',
}
result = {'status': 'pass_artifact_audit', 'utc': datetime.now(timezone.utc).isoformat(),
          'native': native, 'power': powers, 'pixart_layers': layers, 'f2_comparison': comparison}
destination = RUN / 'results/verified_update_20261019.json'
destination.write_text(json.dumps(result, indent=4) + '\n')
(RUN / 'results/f2_comparison.json').write_text(json.dumps(comparison, indent=4) + '\n')
print(json.dumps({'audit': str(destination), 'f2_comparison': comparison}))
