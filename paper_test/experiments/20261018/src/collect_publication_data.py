"""Collect verified native latency and microbenchmark results for the paper workbook."""

import csv
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path


PROJECT = Path('/data/workspaces/zhangcheng/flash_attention')
RUN = PROJECT / 'paper_test/experiments/20261018'


def load(path):
    return json.loads(path.read_text()) if path.exists() else {}


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as handle:
        for block in iter(lambda: handle.read(8 << 20), b''):
            result.update(block)
    return result.hexdigest()


def main():
    result = {'collected_utc': datetime.now(timezone.utc).isoformat(),
              'synthesis': load(PROJECT / 'paper_test/synthesis_summary.json'),
              'native': {}, 'native_energy': {}, 'power': {}, 'layerstep': {},
              'variants': {}, 'gpu_energy': {},
              'traffic': load(RUN / 'results/traffic_study_20261021.json'),
              'f2_comparison': load(RUN / 'results/f2_comparison.json')}
    if result['traffic'].get('state') == 'pass_complete_study':
        for key, report in result['traffic']['results'].items():
            assert report['state'] == 'pass_measured_traffic'
            assert report['functional_byte_exact_pass'] is True
            assert report['macro_count'] == 480 and report['pe_count'] == 1024
            folder = RUN / 'traffic_study_20261021/runs' / key
            for filename, checksum in report['source_sha256'].items():
                assert digest(folder / filename) == checksum
            assert digest(folder / 'result.csv.observed.bin') == (
                report['input_manifest']['files_sha256']['o.bin'])
    f2 = Path('/data/workspaces/zhangcheng/flopa_eval_f2')
    mapped = f2 / 'asic/dc/work/synth/tt/evaluation_f2/attention_accel_top'
    if (mapped / 'results/attention_accel_top.ddc').exists():
        area = (mapped / 'reports/area.rpt').read_text()
        fields = dict(line.split('=', 1) for line in
                      (mapped / 'reports/run_config.rpt').read_text().splitlines() if '=' in line)
        timing = (mapped / 'reports/timing_status.rpt').read_text()
        assert 'setup_violating_paths=0' in timing
        assert fields['sram_macro_count'] == '480' and fields['rtl_icg_count'] == '28'
        result['variants']['F2'] = {
            'area_mm2': float(re.search(r'Total cell area:\s+([\d.]+)', area)[1]) / 1e6,
            'sram_area_mm2': float(re.search(r'Macro/Black Box area:\s+([\d.]+)', area)[1]) / 1e6,
            'sram_macro_count': 480, 'explicit_rtl_icgs': 28, 'target_clock_mhz': 625,
            'area_report_sha256': digest(mapped / 'reports/area.rpt'),
            'ddc_sha256': digest(mapped / 'results/attention_accel_top.ddc'),
            'source': str(mapped), 'physical_timing_signoff': False,
        }
    snapshot = load(RUN / 'checklist_model_snapshot.json')
    for model in ('pixart', 'wan'):
        for n in (1024, 2304, 4096, 9216, 16384):
            key = f'{model}_gpu_energy_{n}'
            result['gpu_energy'][f'{model}_n{n}'] = snapshot.get('items', {}).get(
                key, {}).get('result', {})
    for n in (1024, 4096):
        for model in ('pixart', 'wan'):
            suffix = '' if n == 1024 else f'_n{n}'
            key = model if n == 1024 else f'{model}_n{n}'
            snapshot_key = model + '_layerstep' + suffix + '_gpu'
            result['layerstep'][key] = {
                'gpu': snapshot.get('items', {}).get(snapshot_key, {}).get('result', {}),
                'rtl': load(RUN / 'results' / f'layerstep_{model}{suffix}.json'),
                'completed_layers': sum(load(folder / 'status.json').get('state') == 'pass'
                                        for folder in (RUN / 'jobs').glob(
                                            f'{model}_n{n}_l*_s15')),
            }
    for model, heads, dim in [('pixart', 16, 72), ('wan', 12, 128)]:
        for n in (1024, 2304, 4096, 9216, 16384):
            name = f'{model}_n{n}'
            energy_folder = RUN / 'jobs' / f'power_native_{name}_s301'
            energy = load(energy_folder / 'status.json')
            if energy.get('state') == 'pass':
                assert energy.get('functional_byte_exact_pass') is True
                assert energy.get('all_user_annotation_percent') == 100
                assert energy.get('annotation_conflicts') == 0
                assert energy.get('method') == 'complete native multihead gate SAIF; no sampling'
                assert digest(energy_folder / 'activity.saif') == energy['saif_sha256']
                manifest = energy['manifest']
                assert (manifest['heads'], manifest['nq'], manifest['nkv'], manifest['d']) == (
                    heads, n, n, dim)
                assert digest(energy_folder / 'result.csv.observed.bin') == (
                    manifest['files_sha256']['o.bin'])
                energy['publication_audit'] = 'complete native gate activity; exact output'
            result['native_energy'][name] = energy
            folder = RUN / 'jobs' / name
            report = load(folder / 'status.json')
            if report.get('state') == 'pass':
                manifest = report['manifest']
                assert (manifest['heads'], manifest['nq'], manifest['nkv'], manifest['d']) == (
                    heads, n, n, dim)
                assert digest(folder / 'result.csv.observed.bin') == (
                    manifest['files_sha256']['o.bin'])
                with (folder / 'result.csv').open() as handle:
                    row = next(csv.DictReader(handle))
                assert row['status'] == 'pass' and int(row['cycles']) == report['cycles']
                report['publication_audit'] = 'byte-exact full-head native replay'
            result['native'][name] = report
    for name in ('power_pixart_n256_s301', 'power_wan_n256_s301',
                 'power_f2_pixart_n256_s301', 'power_f1_pixart_n256_s301',
                 'power_pixart_n256_s302', 'power_pixart_n256_s303'):
        report = load(RUN / 'jobs' / name / 'status.json')
        if report.get('state') == 'pass':
            assert report.get('functional_byte_exact_pass') is True
            assert report.get('all_user_annotation_percent') == 100
            assert report.get('annotation_conflicts') == 0
        result['power'][name] = report
    print(json.dumps(result, ensure_ascii=True))


if __name__ == '__main__':
    main()
