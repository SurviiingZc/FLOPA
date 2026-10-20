"""Keep the current README and plan consistent with corrected power analysis."""

import fcntl
from pathlib import Path


root = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
run = root / 'experiments/20261018'
lock = (run / 'checklist_update.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX)
note = ('> 2026-10-20功耗回读修正：原约5W受DC默认1001pF高扇出简化负载影响。'
        '同一DDC/SAIF以high_fanout_net_threshold=0重新回读，F0 d72为0.5740094W、'
        'F0 d128为0.5996562W、F2 d72为0.5556435W；匹配能量减少3.65%。'
        '这些仍为实际库pin负载、ZeroWireload/preCTS IP估计；未重综合，'
        '旧结果留存审计而不再作当前主结果。详见results中的actual_pin_load_power_audit。\n\n')
for name in ('README.md', 'EVALUATION_PLAN_ZH.md', 'ENERGY_EVALUATION_ZH.md'):
    path = root / name
    text = path.read_text()
    if '2026-10-20功耗回读修正' not in text:
        path.write_text(note + text, encoding='utf-8')
ignore = run / '.gitignore'
text = ignore.read_text()
if 'clock_load_audit_*/' not in text:
    text = text.rstrip() + '\nclock_load_audit_*/\n'
if 'publication_update.lock' not in text:
    text = text.rstrip() + '\npublication_update.lock\n'
ignore.write_text(text)
