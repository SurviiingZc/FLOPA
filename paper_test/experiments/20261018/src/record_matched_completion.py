"""Mark the audited matched schedule result while retaining pending review items."""

import fcntl
import json
from pathlib import Path


root = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
run = root / 'experiments/20261018'
lock = (run / 'checklist_update.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX)
evidence = run / 'results/f2_comparison.json'
assert json.loads(evidence.read_text())['status'] == 'pass_matched_gate_evidence'
manual = run / 'checklist_manual.json'
values = json.loads(manual.read_text())
values['f2_comparison'] = {
    'done': True, 'status': '同输入门级核验通过；周期降6.73%、IP估计能量降5.04%；时钟审查另列',
    'evidence': str(evidence),
}
manual.write_text(json.dumps(values, ensure_ascii=False, indent=4) + '\n', encoding='utf-8')
