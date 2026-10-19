"""Submit or audit an approved full-vector replay using the frozen executable."""

import argparse
import csv
import fcntl
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path('/data/workspaces/zhangcheng/flash_attention/paper_test/experiments/20261018')


def sha(path):
    value = hashlib.sha256()
    with path.open('rb') as handle:
        for part in iter(lambda: handle.read(8 << 20), b''):
            value.update(part)
    return value.hexdigest()


def write(path, report):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(report, indent=4) + '\n')
    temporary.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--name', required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--status', action='store_true')
    args = parser.parse_args()
    assert args.name.startswith(('pixart_n', 'wan_n'))
    assert all(char.isalnum() or char == '_' for char in args.name)
    folder = ROOT / 'inputs' / args.name
    target = ROOT / 'jobs' / args.name
    target.mkdir(parents=True, exist_ok=True)
    status = target / 'status.json'
    if args.status:
        print(status.read_text() if status.exists() else json.dumps({'state': 'starting'}))
        return
    if not args.worker:
        if status.exists():
            print(status.read_text())
            return
        with (target / 'worker.log').open('w') as log:
            child = subprocess.Popen([sys.executable, __file__, '--name', args.name, '--worker'],
                stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                cwd=str(target), start_new_session=True)
        print(json.dumps({'state': 'submitted', 'wrapper_pid': child.pid}))
        return
    lock_handle = (target / 'worker.lock').open('w')
    fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    manifest = json.loads((folder / 'replay_manifest.json').read_text())
    for name, digest in manifest['files_sha256'].items():
        assert name in ('q.bin', 'k.bin', 'v.bin', 'o.bin')
        assert sha(folder / name) == digest, name
    assert manifest['nq'] in (1024, 2304, 4096, 9216, 16384)
    assert manifest['nkv'] == manifest['nq']
    assert (manifest['heads'], manifest['d']) in ((16, 72), (12, 128))
    executable = ROOT / 'replay_build/simv'
    if manifest['nq'] >= 9216:
        readiness = ROOT / 'replay_build_long/ready.json'
        assert readiness.exists(), 'Long-watchdog executable not yet qualified'
        ready = json.loads(readiness.read_text())
        executable = ROOT / 'replay_build_long/simv'
        assert sha(executable) == ready['executable_sha256']
    started = time.time()
    report = {'state': 'running', 'manifest': manifest, 'start_unix': started,
              'executable_sha256': sha(executable), 'clock_period_ns': 1.6,
              'scope': 'full-head native-shape RTL, ideal 128-bit streaming service',
              'frequency_status': 'synthesis target, not measured silicon'}
    report['accuracy_pass'] = manifest.get('accuracy_pass', True)
    report['precision_gate_is_diagnostic'] = manifest.get('precision_gate_is_diagnostic', False)
    report['functional_pass_does_not_imply_accuracy_pass'] = True
    write(status, report)
    command = [str(executable), '+VECTOR_DIR=' + str(folder),
        '+RESULT=' + str(target / 'result.csv'), '+NQ=' + str(manifest['nq']),
        '+NKV=' + str(manifest['nkv']), '+HEADS=' + str(manifest['heads']),
        '+DIM=' + str(manifest['d']), '+SCORE_SCALE={:08x}'.format(manifest['score_scale']),
        '+OUT_SCALE={:08x}'.format(manifest['out_scale']), '+CLK_PERIOD_NS=1.6',
        '+no_notifier', '+notimingcheck', '-l', str(target / 'run.log')]
    with (target / 'console.log').open('w') as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    run_log = (target / 'run.log').read_text(errors='replace')
    passed = (result.returncode == 0 and '[PASS] tb_paper_replay' in run_log and
              'BYTE_MISMATCH' not in run_log and 'Fatal:' not in run_log)
    report.update(state='pass' if passed else 'failed', elapsed_seconds=time.time() - started,
                  process_exit=result.returncode)
    if passed:
        row = next(csv.DictReader((target / 'result.csv').open()))
        assert sha(target / 'result.csv.observed.bin') == manifest['files_sha256']['o.bin']
        report.update(cycles=int(row['cycles']),
                      latency_ms=int(row['cycles']) * 1.6e-6,
                      loader_bytes=int(row['loader_bytes']),
                      output_bytes=int(row['output_bytes']))
    write(status, report)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        if '--worker' in sys.argv and '--name' in sys.argv and not isinstance(
                error, BlockingIOError):
            name = sys.argv[sys.argv.index('--name') + 1]
            if name.startswith(('pixart_n', 'wan_n')) and all(
                    char.isalnum() or char == '_' for char in name):
                directory = ROOT / 'jobs' / name
                directory.mkdir(parents=True, exist_ok=True)
                write(directory / 'status.json', {
                    'state': 'failed', 'stage': 'wrapper validation or execution',
                    'error': repr(error),
                })
        raise
