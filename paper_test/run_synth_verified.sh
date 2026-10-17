#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="${VALIDATION_MANIFEST:-$ROOT_DIR/paper_test/validation_manifest.json}"
test -s "$MANIFEST"

VALIDATED_ENV=$(python3 - "$ROOT_DIR" "$MANIFEST" <<'PY'
import hashlib
import json
import shlex
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
manifest = Path(sys.argv[2]).resolve()
data = json.loads(manifest.read_text())
assert data['status'] == 'pass', 'Functional validation has not passed'
commit = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'],
                                 universal_newlines=True).strip()
assert commit == data['git_commit'], 'Validation belongs to a different commit'
for path in ('rtl', 'tb', 'asic/scripts', 'asic/constraints', 'Makefile'):
    changed = subprocess.check_output(
        ['git', '-C', str(root), 'diff', 'HEAD', '--', path],
        universal_newlines=True,
    )
    assert not changed, 'Uncommitted source/config changes: ' + path
assert data['tests'] and all(test['status'] == 'pass' for test in data['tests'])
for test in data['tests']:
    log = (root / test['log']).resolve()
    assert root in log.parents and log.is_file(), 'Missing validation log'
    assert hashlib.sha256(log.read_bytes()).hexdigest() == test['log_sha256']
for key, name in (
    ('expected_sram_macros', 'EXPECTED_TOP_SRAM_MACROS'),
    ('expected_rtl_icgs', 'EXPECTED_TOP_RTL_ICGS'),
):
    value = data[key]
    assert isinstance(value, int) and value > 0, key
    print('export {}={}'.format(name, shlex.quote(str(value))))
digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
print('export FA_VALIDATION_MANIFEST_HASH=' + shlex.quote(digest))
PY
)
eval "$VALIDATED_ENV"

export CLOCK_PERIOD="${CLOCK_PERIOD:-1.6}"
export DC_CORES="${DC_CORES:-16}"
export CORNER="${CORNER:-tt}"
export TMPDIR="$ROOT_DIR/asic/dc/work/tmp"
mkdir -p "$TMPDIR"
"$ROOT_DIR/asic/scripts/run_synth.sh" diffusion_runtime_d attention_accel_top
