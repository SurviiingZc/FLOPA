#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: bash run_audit.sh MAPPED_DDC RUN_CONFIG NEW_REPORT_DIR" >&2
    exit 2
fi

export FA_ROOT="${FA_ROOT:-/data/workspaces/zhangcheng/flash_attention}"
export FA_DDC_FILE
export FA_RUN_CONFIG
export FA_CLOCK_AUDIT_DIR
FA_DDC_FILE=$(readlink -f -- "$1")
FA_RUN_CONFIG=$(readlink -f -- "$2")
FA_CLOCK_AUDIT_DIR=$(readlink -m -- "$3")
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

for file in "$FA_DDC_FILE" "$FA_RUN_CONFIG"; do
    if [[ ! -s "$file" ]]; then
        echo "Missing/empty final synthesis artifact: $file" >&2
        exit 2
    fi
done
if [[ -e "$FA_CLOCK_AUDIT_DIR/summary.json" ]]; then
    echo "Refusing to overwrite a previous audit; choose a fresh report directory" >&2
    exit 2
fi
mkdir -p -- "$FA_CLOCK_AUDIT_DIR"
cd -- "$FA_CLOCK_AUDIT_DIR"

# CWD and all reports are outside the synthesis result directory. No design is written.
set +e
dc_shell -64bit -f "$script_dir/audit_mapped_clocks.tcl" 2>&1 | tee console.log
status=${PIPESTATUS[0]}
set -e

# DC can print Error without throwing Tcl exceptions. Such an audit cannot pass.
python3 - "$status" "$FA_CLOCK_AUDIT_DIR" <<'PY'
import json
import re
import sys
from pathlib import Path

code = int(sys.argv[1])
root = Path(sys.argv[2])
path = root / 'summary.json'
issues = []
if path.exists():
    summary = json.loads(path.read_text())
else:
    summary = {'overall_status': 'UNKNOWN'}
    issues.append('DC did not produce summary.json')
if code != 0:
    issues.append('dc_shell exit code: {}'.format(code))
console = (root / 'console.log').read_text(errors='replace')
if re.search(r'^\s*(?:Error:|ERROR:)', console, flags=re.MULTILINE):
    issues.append('DC printed an Error message; inspect console.log')
if issues and summary.get('overall_status') != 'FAIL':
    summary['overall_status'] = 'UNKNOWN'
summary['launcher_findings'] = '\n'.join(issues)
path.write_text(json.dumps(summary, indent=4) + '\n')
print('CLOCK_AUDIT_FINAL_STATUS=' + summary['overall_status'])
sys.exit(0 if summary['overall_status'] == 'PASS' else 2)
PY
