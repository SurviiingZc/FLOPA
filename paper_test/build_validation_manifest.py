"""Bind the complete short suite and module checks to a committed source tree."""

import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path

root = Path(__file__).resolve().parents[1]
output = root / 'tb/sim/build/runtime_d'
summary = json.loads((output / 'summary.json').read_text())
required = {
    'fa_runtime_d_smoke_test': 5,
    'fa_runtime_d_range_test': 128,
    'fa_runtime_d_boundary_test': 12,
    'fa_runtime_d_multihead_test': 3,
    'fa_runtime_d_control_test': 3,
    'fa_runtime_d_arith_test': 6,
}
assert summary['pass']
assert {test['test'] for test in summary['tests']} == set(required)
for test in summary['tests']:
    assert test['pass'] and test['uvm_errors'] == test['uvm_fatals'] == 0
    assert test['completed_jobs'] >= required[test['test']]

compile_manifest = json.loads((output / 'compile_manifest.json').read_text())
assert compile_manifest['compile_before_sha256'] == compile_manifest['source_sha256']
assert compile_manifest['compile_after_sha256'] == compile_manifest['source_sha256']
for item in compile_manifest['files'] + compile_manifest['sram_models']:
    path = Path(item['path'])
    if not path.is_absolute():
        path = root / path
    assert path.is_file(), path
    assert hashlib.sha256(path.read_bytes()).hexdigest() == item['sha256'], path
assert hashlib.sha256((output / 'simv').read_bytes()).hexdigest() == (
    compile_manifest['simv_sha256']
)
modules = json.loads((output / 'module_summary.json').read_text())
assert modules['pass'] and modules['tests'], 'Module checks have not passed'
tests = []
for test in summary['tests']:
    tests.append({
        'name': test['test'], 'status': 'pass', 'log': test['log'],
        'completed_jobs': test['completed_jobs'], 'checked_bytes': test['checked_bytes'],
    })
for test in modules['tests']:
    assert test['pass'], test
    tests.append({'name': test['test'], 'status': 'pass', 'log': test['log']})
for test in tests:
    log = Path(test['log'])
    if not log.is_absolute():
        log = root / log
    log = log.resolve()
    assert root in log.parents and log.is_file()
    test['log'] = str(log.relative_to(root))
    test['log_sha256'] = hashlib.sha256(log.read_bytes()).hexdigest()

commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'],
    universal_newlines=True).strip()
result = {
    'status': 'pass', 'timestamp_utc': datetime.now(timezone.utc).isoformat(),
    'git_commit': commit, 'expected_sram_macros': 480, 'expected_rtl_icgs': 28,
    'max_d': 128, 'tests': tests, 'compile_manifest': compile_manifest,
    'completed_jobs': sum(test['completed_jobs'] for test in summary['tests']),
    'checked_bytes': sum(test['checked_bytes'] for test in summary['tests']),
    'scope': 'short functional RTL with characterized ASIC SRAM behavior; no SDF',
}
destination = root / 'paper_test/validation_manifest.json'
destination.write_text(json.dumps(result, indent=4) + '\n')
print('Validated commit:', commit)
print('Jobs:', result['completed_jobs'], 'checked bytes:', result['checked_bytes'])
print(destination)
