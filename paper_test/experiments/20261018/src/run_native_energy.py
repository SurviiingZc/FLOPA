"""Audit complete native multihead gate activity, without head or length extrapolation."""

import argparse
import csv
import fcntl
import json
import re
import shutil
import subprocess
import sys
import time

from submit_replay import ROOT, sha, write


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', choices=['pixart', 'wan'], required=True)
    parser.add_argument('--n', type=int, choices=[1024, 2304, 4096, 9216, 16384], required=True)
    parser.add_argument('--worker', action='store_true')
    args = parser.parse_args()
    key = f'{args.model}_n{args.n}'
    name = f'power_native_{key}_s301'
    target = ROOT / 'jobs' / name
    target.mkdir(parents=True, exist_ok=True)
    status = target / 'status.json'
    if not args.worker:
        if status.exists():
            print(status.read_text())
            return
        with (target / 'worker.log').open('w') as log:
            child = subprocess.Popen(
                [sys.executable, __file__, '--model', args.model, '--n', str(args.n),
                 '--worker'], stdin=subprocess.DEVNULL, stdout=log,
                stderr=subprocess.STDOUT, cwd=str(target), start_new_session=True)
        print(json.dumps({'state': 'submitted', 'name': name, 'pid': child.pid}))
        return
    lock = (target / 'worker.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    report = {'state': 'validating_inputs', 'started_unix': time.time(),
              'model': args.model, 'n': args.n,
              'method': 'complete native multihead gate SAIF; no sampling',
              'energy_unit': 'mJ per complete multihead SDPA',
              'precision_qualification': 'deferred; integer implementation equivalence only'}
    write(status, report)
    try:
        assert shutil.disk_usage(ROOT).free > 2 * (1 << 30), 'Less than 2 GiB available'
        folder = ROOT / 'inputs' / key
        manifest = json.loads((folder / 'replay_manifest.json').read_text())
        heads, dim = (16, 72) if args.model == 'pixart' else (12, 128)
        assert (manifest['heads'], manifest['nq'], manifest['nkv'], manifest['d']) == (
            heads, args.n, args.n, dim)
        for filename, digest in manifest['files_sha256'].items():
            assert filename in ('q.bin', 'k.bin', 'v.bin', 'o.bin')
            assert sha(folder / filename) == digest
        assert sha(folder / 'qualification.json') == manifest['qualification_sha256']
        rtl = json.loads((ROOT / 'jobs' / key / 'status.json').read_text())
        assert rtl['state'] == 'pass', 'Native RTL baseline must first pass'
        executable = ROOT / 'gate_pilot_build/simv'
        mapped = ROOT.parents[2] / 'asic/dc/work/synth/tt/diffusion_runtime_d'
        mapped = mapped / 'attention_accel_top/results'
        netlist_hash = sha(mapped / 'attention_accel_top_mapped.v')
        ddc_hash = sha(mapped / 'attention_accel_top.ddc')
        assert netlist_hash == (
            '58bd512cea82c41bc64641364b732255b55f12d450bf72ca6343a8a7324d2f85')
        assert ddc_hash == (
            'b03b398f2e2cac9274fe9c02b1aa8d8fa10d3cefe6537aae68dfcdeae22129f2')
        report.update(state='gate_running', manifest=manifest,
                      executable_sha256=sha(executable),
                      mapped_netlist_sha256=netlist_hash, mapped_ddc_sha256=ddc_hash,
                      expected_cycles=rtl['cycles'], clock_period_ns=1.6)
        write(status, report)
        command = [str(executable), '+VECTOR_DIR=' + str(folder),
                   '+RESULT=' + str(target / 'result.csv'), '+NQ=' + str(args.n),
                   '+NKV=' + str(args.n), '+HEADS=' + str(heads), '+DIM=' + str(dim),
                   '+CLK_PERIOD_NS=1.6', '+SCORE_SCALE={:08x}'.format(manifest['score_scale']),
                   '+OUT_SCALE={:08x}'.format(manifest['out_scale']), '+SAIF_ENABLE',
                   '+SAIF_FILE=' + str(target / 'activity.saif'), '+no_notifier',
                   '+notimingcheck', '-l', str(target / 'run.log')]
        with (target / 'console.log').open('w') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            report['simulation_pid'] = process.pid
            write(status, report)
            assert process.wait() == 0, 'Gate simulation exited unsuccessfully'
        log = (target / 'run.log').read_text(errors='replace')
        assert '[PASS] tb_paper_replay' in log
        assert not re.search(r'BYTE_MISMATCH|Fatal:|[Cc]onflict', log)
        assert sha(target / 'result.csv.observed.bin') == manifest['files_sha256']['o.bin']
        with (target / 'result.csv').open() as handle:
            row = next(csv.DictReader(handle))
        cycles = int(row['cycles'])
        assert cycles == rtl['cycles'], 'Gate/RTL cycles differ'
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
                      functional_byte_exact_pass=True)
        write(status, report)
        subprocess.run(['bash', str(ROOT / 'src/read_native_energy.sh'), name], check=True)
        power_dir = target / 'power_reports_actual_pin_load'
        coverage = (power_dir / 'saif_coverage.rpt').read_text()
        for category in ('Nets', 'Ports', 'Pins'):
            assert re.search(r'\b' + category + r'\s+\d+\(100\.00%\)', coverage)
        power_log = (target / 'power_work_actual_pin_load/console.log').read_text()
        assert not re.search(r'\(PWR-18\)|\(PWR-19\)', power_log + coverage)
        summary = (power_dir / 'power_summary.rpt').read_text()
        values = {}
        for field, label in [('dynamic_w', 'Total Dynamic Power'),
                             ('leakage_w', 'Cell Leakage Power')]:
            match = re.search(label + r'\s*=\s*([\d.eE+-]+)\s*(mW|nW|uW|W)', summary)
            assert match, label
            values[field] = float(match[1]) * {'W': 1, 'mW': 1e-3,
                                              'uW': 1e-6, 'nW': 1e-9}[match[2]]
        values['total_w'] = values['dynamic_w'] + values['leakage_w']
        seconds = active_ns * 1e-9
        macs = 2 * heads * args.n * args.n * dim
        values.update(energy_job_j=values['total_w'] * seconds,
                      energy_full_head_mj=values['total_w'] * seconds * 1e3,
                      effective_tops=2 * macs / seconds / 1e12)
        report.update(state='pass', activity_based_estimate=values,
                      power_report_directory=power_dir.name,
                      load_model='actual pin loads; high_fanout_net_threshold=0; pre-CTS',
                      all_user_annotation_percent=100, annotation_conflicts=0,
                      scope='mapped IP, 625-MHz target; excludes DRAM/PHY/host/physical CTS',
                      elapsed_seconds=time.time() - report['started_unix'])
        write(status, report)
    except Exception as error:
        report.update(state='failed', error=repr(error),
                      elapsed_seconds=time.time() - report['started_unix'])
        write(status, report)
        raise


if __name__ == '__main__':
    main()
