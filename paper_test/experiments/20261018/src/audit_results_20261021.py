"""Audit current outputs and retain incomplete layers as partial coverage only."""

import csv
import json
from datetime import datetime, timedelta, timezone

from collect_publication_data import RUN, digest, load


def verify(name, heads, n, dim):
    folder = RUN / 'jobs' / name
    report = load(folder / 'status.json')
    assert report['state'] == 'pass', name
    manifest = report['manifest']
    assert (manifest['heads'], manifest['nq'], manifest['nkv'], manifest['d']) == (
        heads, n, n, dim), name
    with (folder / 'result.csv').open() as handle:
        row = next(csv.DictReader(handle))
    assert row['status'] == 'pass' and int(row['cycles']) == report['cycles'], name
    assert digest(folder / 'result.csv.observed.bin') == manifest['files_sha256']['o.bin']
    text = (folder / 'run.log').read_text(errors='replace')
    assert '[PASS] tb_paper_replay' in text and 'BYTE_MISMATCH' not in text, name
    assert 'Fatal:' not in text, name
    return {'cycles': report['cycles'], 'latency_ms': report['cycles'] * 1.6e-6,
            'status_sha256': digest(folder / 'status.json'),
            'observed_sha256': digest(folder / 'result.csv.observed.bin')}


result = {'status': 'pass_artifact_audit', 'native': {}, 'layers': {},
          'native_energy': {}, 'updated': datetime.now(
              timezone(timedelta(hours=8))).isoformat(timespec='seconds')}
for model, heads, dim, layers in [('pixart', 16, 72, 28), ('wan', 12, 128, 30)]:
    for n in (1024, 2304, 4096, 9216, 16384):
        name = f'{model}_n{n}'
        report = load(RUN / 'jobs' / name / 'status.json')
        result['native'][name] = verify(name, heads, n, dim) if report.get(
            'state') == 'pass' else {'state': report.get('state', 'not_started')}
        energy = load(RUN / 'jobs' / f'power_native_{name}_s301' / 'status.json')
        result['native_energy'][name] = {
            'state': energy.get('state', 'not_started'),
            'simulation_pid': energy.get('simulation_pid'),
            'result_available': energy.get('state') == 'pass'}
    for n in (1024, 4096):
        checked = {}
        for index in range(layers):
            name = f'{model}_n{n}_l{index:02d}_s15'
            report = load(RUN / 'jobs' / name / 'status.json')
            if report.get('state') == 'pass':
                checked[name] = verify(name, heads, n, dim)
        entry = {'completed_layers': len(checked), 'required_layers': layers,
                 'status': 'pass_all_layers' if len(checked) == layers else 'partial_coverage',
                 'jobs': checked}
        if len(checked) == layers:
            entry['cycles'] = sum(item['cycles'] for item in checked.values())
            entry['latency_ms'] = entry['cycles'] * 1.6e-6
        result['layers'][f'{model}_n{n}'] = entry
destination = RUN / 'results/verified_update_20261021.json'
destination.write_text(json.dumps(result, indent=4) + '\n')
print(json.dumps({
    'native_pass': sum('cycles' in value for value in result['native'].values()),
    'layers': {key: (value['completed_layers'], value['required_layers'])
               for key, value in result['layers'].items()},
    'native_energy_pass': sum(value['result_available']
                              for value in result['native_energy'].values()),
    'audit': str(destination)}, indent=4))
