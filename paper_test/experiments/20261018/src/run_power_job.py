"""Run and audit the F0 real-input microbenchmark using the frozen gate executable."""

import argparse
import csv
import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from submit_replay import ROOT, sha, write


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', choices=['pixart', 'wan'], required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--variant', choices=['F0', 'F2'], default='F0')
    args = parser.parse_args()
    input_name = 'power_' + args.model + '_n256_s301'
    name = input_name if args.variant == 'F0' else 'power_f2_' + args.model + '_n256_s301'
    assert args.variant != 'F2' or args.model == 'pixart'
    folder = ROOT / 'inputs' / input_name
    target = ROOT / 'jobs' / name
    target.mkdir(parents=True, exist_ok=True)
    status_path = target / 'status.json'
    if not args.worker:
        if status_path.exists():
            print(status_path.read_text())
            return
        with (target / 'worker.log').open('w') as log:
            child = subprocess.Popen([sys.executable, __file__, '--model', args.model,
                '--variant', args.variant, '--worker'],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                cwd=str(target), start_new_session=True)
        print(json.dumps({'state': 'submitted', 'pid': child.pid}))
        return
    lock = (target / 'worker.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    report = {'state': 'validating_inputs', 'started_unix': time.time(),
              'variant': args.variant,
              'precision_qualification': 'deferred; current integer arithmetic only'}
    write(status_path, report)
    try:
        manifest = json.loads((folder / 'replay_manifest.json').read_text())
        assert (manifest['heads'], manifest['nq'], manifest['nkv']) == (1, 256, 256)
        assert manifest['d'] == (72 if args.model == 'pixart' else 128)
        for filename, digest in manifest['files_sha256'].items():
            assert filename in ('q.bin', 'k.bin', 'v.bin', 'o.bin')
            assert sha(folder / filename) == digest
        assert sha(folder / 'qualification.json') == manifest['qualification_sha256']
        executable = ROOT / 'gate_pilot_build/simv'
        mapped = Path('/data/workspaces/zhangcheng/flash_attention/asic/dc/work/synth/tt') / (
            'diffusion_runtime_d/attention_accel_top/results')
        if args.variant == 'F0':
            assert sha(mapped / 'attention_accel_top_mapped.v') == (
                '58bd512cea82c41bc64641364b732255b55f12d450bf72ca6343a8a7324d2f85')
            assert sha(mapped / 'attention_accel_top.ddc') == (
                'b03b398f2e2cac9274fe9c02b1aa8d8fa10d3cefe6537aae68dfcdeae22129f2')
        else:
            variant_root = Path('/data/workspaces/zhangcheng/flopa_eval_f2')
            mapped = variant_root / 'asic/dc/work/synth/tt/evaluation_f2' / (
                'attention_accel_top/results')
            build = variant_root / 'paper_test/f2_gate_build'
            ready = json.loads((build / 'ready.json').read_text())
            executable = build / 'simv'
            assert sha(executable) == ready['executable_sha256']
            assert sha(mapped / 'attention_accel_top_mapped.v') == ready['netlist_sha256']
            assert sha(mapped / 'attention_accel_top.ddc') == ready['ddc_sha256']
        report.update(state='gate_running', manifest=manifest,
                      executable_sha256=sha(executable),
                      mapped_netlist_sha256=sha(mapped / 'attention_accel_top_mapped.v'),
                      mapped_ddc_sha256=sha(mapped / 'attention_accel_top.ddc'))
        write(status_path, report)
        command = [str(executable), '+VECTOR_DIR=' + str(folder),
            '+RESULT=' + str(target / 'result.csv'), '+NQ=256', '+NKV=256', '+HEADS=1',
            '+DIM=' + str(manifest['d']), '+CLK_PERIOD_NS=1.6',
            '+SCORE_SCALE={:08x}'.format(manifest['score_scale']),
            '+OUT_SCALE={:08x}'.format(manifest['out_scale']), '+SAIF_ENABLE',
            '+SAIF_FILE=' + str(target / 'activity.saif'), '+no_notifier', '+notimingcheck',
            '-l', str(target / 'run.log')]
        with (target / 'console.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
        text = (target / 'run.log').read_text(errors='replace')
        assert '[PASS] tb_paper_replay' in text
        assert not re.search(r'BYTE_MISMATCH|Fatal:|[Cc]onflict', text)
        assert sha(target / 'result.csv.observed.bin') == manifest['files_sha256']['o.bin']
        row = next(csv.DictReader((target / 'result.csv').open()))
        cycles = int(row['cycles'])
        with (target / 'activity.saif').open() as handle:
            header = handle.read(4096)
        unit = re.search(r'\(TIMESCALE\s+([\d.eE+-]+)\s+(\w+)\)', header)
        duration = re.search(r'\(DURATION\s+([\d.eE+-]+)\)', header)
        assert unit and duration
        resolution = float(unit[1]) * {'ps': 0.001, 'ns': 1, 'us': 1000}[unit[2]]
        active_ns = float(duration[1]) * resolution
        assert abs(active_ns - cycles * 1.6) <= resolution + 1e-9
        report.update(state='power_readback', cycles=cycles, saif_active_ns=active_ns,
                      saif_sha256=sha(target / 'activity.saif'),
                      clock_period_ns=1.6, functional_byte_exact_pass=True)
        write(status_path, report)
        subprocess.run(['bash', str(ROOT / 'src/read_power_job.sh'), name], check=True)
        actual_load = os.environ.get('FA_ACTUAL_PIN_LOAD', '1') == '1'
        report_folder = 'power_reports_actual_pin_load' if actual_load else 'power_reports'
        coverage = (target / report_folder / 'saif_coverage.rpt').read_text()
        for category in ('Nets', 'Ports', 'Pins'):
            assert re.search(r'\b' + category + r'\s+\d+\(100\.00%\)', coverage)
        summary = (target / report_folder / 'power_summary.rpt').read_text()
        values = {}
        for field, label in [('dynamic_w', 'Total Dynamic Power'),
                             ('leakage_w', 'Cell Leakage Power')]:
            match = re.search(label + r'\s*=\s*([\d.eE+-]+)\s*(mW|nW|uW|W)', summary)
            assert match, label
            values[field] = float(match[1]) * {'W': 1, 'mW': 1e-3,
                                              'uW': 1e-6, 'nW': 1e-9}[match[2]]
        values['total_w'] = values['dynamic_w'] + values['leakage_w']
        macs = 2 * 256 * 256 * manifest['d']
        seconds = active_ns * 1e-9
        values['energy_job_j'] = values['total_w'] * seconds
        values['pj_per_mac'] = values['energy_job_j'] / macs * 1e12
        values['effective_tops'] = 2 * macs / seconds / 1e12
        report.update(state='pass', activity_based_estimate=values,
                      power_report_directory=report_folder,
                      load_model=('actual pin loads; high_fanout_net_threshold=0; pre-CTS'
                                  if actual_load else 'legacy default high-fanout approximation'),
                      scope='mapped pre-layout IP, 625-MHz target, no external memory',
                      all_user_annotation_percent=100, annotation_conflicts=0,
                      elapsed_seconds=time.time() - report['started_unix'])
        write(status_path, report)
        updater = ROOT / 'src/update_readme_checklist.py'
        if updater.exists():
            try:
                subprocess.run([sys.executable, str(updater)], check=True)
            except Exception as error:
                print('CHECKLIST_UPDATE_ERROR', repr(error), flush=True)
    except Exception as error:
        report.update(state='failed', error=repr(error))
        write(status_path, report)
        raise


if __name__ == '__main__':
    main()
