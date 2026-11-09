"""Finite continuation of the already approved frozen-RTL experiment matrix."""

import fcntl
import json
import os
import shutil
import subprocess
import sys
import time
import traceback

from submit_replay import ROOT, sha, write


ACTIVE = {'running', 'gate_running', 'power_readback', 'validating_inputs'}
MODELS = {'pixart': 28, 'wan': 30}
LENGTHS = (1024, 2304, 4096, 9216, 16384)
ENERGY_ORDER = (4096, 2304, 9216, 16384, 1024)
QUEUE = ROOT / 'continuation_20261022'


def status(name):
    path = ROOT / 'jobs' / name / 'status.json'
    return json.loads(path.read_text()) if path.exists() else {'state': 'pending'}


def invoke(script, *arguments):
    command = [sys.executable, str(ROOT / 'src' / script), *arguments]
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True, timeout=120)
    if result.returncode:
        raise RuntimeError(result.stderr[-4000:])
    print(time.strftime('%Y-%m-%dT%H:%M:%S'), script, *arguments, result.stdout.strip(),
          flush=True)


def verified(name, item):
    if item['state'] != 'pass':
        return False
    manifest = item.get('manifest')
    if manifest is not None:
        observed = ROOT / 'jobs' / name / 'result.csv.observed.bin'
        if sha(observed) != manifest['files_sha256']['o.bin']:
            raise RuntimeError('Passed output hash changed: ' + name)
    return True


def publish_layers(model, length, names, states):
    suffix = '' if length == 1024 else '_n' + str(length)
    path = ROOT / 'results' / ('layerstep_' + model + suffix + '.json')
    if path.exists():
        return
    if not all(verified(name, states[name]) for name in names):
        return
    cycles = sum(states[name]['cycles'] for name in names)
    report = {
        'status': 'pass_all_layers', 'model': model, 'layers': len(names),
        'n': length, 'step_index': 15, 'branch': 'conditional', 'cycles': cycles,
        'latency_ms': cycles * 1.6e-6, 'jobs': names,
        'scope': 'sum of verified full-head RTL calls; one conditional diffusion step',
        'not_full_denoiser_latency': True, 'integer_equivalence_only': True,
    }
    write(path, report)
    print('PUBLISHED', path.name, cycles, flush=True)


def main():
    QUEUE.mkdir(exist_ok=True)
    lock = (QUEUE / 'queue.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    expected = []
    for model, layers in MODELS.items():
        expected += [f'{model}_n{length}' for length in LENGTHS]
        expected += [f'power_native_{model}_n{length}_s301' for length in LENGTHS]
        for length in (1024, 4096):
            expected += [f'{model}_n{length}_l{layer:02d}_s15'
                         for layer in range(layers)]
    while True:
        try:
            states = {name: status(name) for name in expected}
            failed = [name for name, item in states.items() if item['state'] == 'failed']
            free = shutil.disk_usage(ROOT).free
            can_submit = free >= 20 * (1 << 30)
            submitted = []
            for model, layers in MODELS.items():
                native = [f'{model}_n{length}' for length in LENGTHS]
                busy = any(states[name]['state'] in ACTIVE for name in native)
                if can_submit and not busy:
                    for name in native:
                        if states[name]['state'] == 'pending':
                            invoke('submit_replay.py', '--name', name)
                            states[name] = status(name)
                            submitted.append(name)
                            break
                layer_names = []
                for length in (1024, 4096):
                    names = [f'{model}_n{length}_l{layer:02d}_s15'
                             for layer in range(layers)]
                    layer_names += names
                    publish_layers(model, length, names, states)
                busy = sum(states[name]['state'] in ACTIVE for name in layer_names)
                for name in layer_names:
                    if not can_submit or busy >= 4:
                        break
                    if states[name]['state'] == 'pending':
                        invoke('submit_replay.py', '--name', name)
                        states[name] = status(name)
                        submitted.append(name)
                        busy += 1
            power_busy = sum(item['state'] in ACTIVE for name, item in states.items()
                             if name.startswith('power_native_'))
            for length in ENERGY_ORDER:
                for model in MODELS:
                    name = f'power_native_{model}_n{length}_s301'
                    baseline = f'{model}_n{length}'
                    if (can_submit and power_busy < 2 and
                            states[name]['state'] == 'pending' and
                            states[baseline]['state'] == 'pass'):
                        invoke('run_native_energy.py', '--model', model, '--n', str(length))
                        states[name] = status(name)
                        submitted.append(name)
                        power_busy += 1
            completed = sum(item['state'] == 'pass' for item in states.values())
            running = [name for name, item in states.items() if item['state'] in ACTIVE]
            write(QUEUE / 'status.json', {
                'pid': os.getpid(), 'updated_unix': time.time(), 'completed': completed,
                'total': len(expected), 'running': running, 'failed': failed,
                'free_gib': free / (1 << 30), 'disk_guard_pauses_new_jobs': not can_submit,
                'submitted_this_round': submitted, 'precision_optimization': 'deferred',
                'scope': 'finite approved experiment queue; exits after all terminal states',
            })
            invoke('update_readme_checklist.py')
            if not running and completed + len(failed) == len(expected):
                print('QUEUE_FINISHED', 'failed=' + str(failed), flush=True)
                return
        except Exception:
            traceback.print_exc()
            sys.stdout.flush()
        time.sleep(60)


if __name__ == '__main__':
    main()
