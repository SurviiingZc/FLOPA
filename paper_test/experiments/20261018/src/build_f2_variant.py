"""Make the approved isolated F2 control change; preserve the F0 working tree."""

import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path('/data/workspaces/zhangcheng/flopa_eval_f2')
path = ROOT / 'rtl/attention_accel_top.v'
original = path.read_text()
before = '.qk_done_i(qk_done_w), .softmax_pv_ready_i(softmax_pv_ready_w),'
after = '.qk_done_i(qk_done_w), .softmax_pv_ready_i(softmax_done_w),'
assert original.count(before) == 1
path.write_text(original.replace(before, after))
report = {
    'variant': 'F2', 'baseline_commit': '6fa4607',
    'scope': 'PV waits for softmax row-state completion; other datapaths unchanged',
    'file': 'rtl/attention_accel_top.v',
    'before_sha256': hashlib.sha256(original.encode()).hexdigest(),
    'after_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
    'numerical_rtl_changed': False,
}
target = ROOT / 'paper_test/f2_control_change.json'
target.write_text(json.dumps(report, indent=4) + '\n')
subprocess.run(['git', '-C', str(ROOT), 'add', 'rtl/attention_accel_top.v',
                'paper_test/f2_control_change.json'], check=True)
subprocess.run(['git', '-C', str(ROOT), 'commit', '-m',
                'test: isolate PV versus row-state overlap for F2'], check=True)
