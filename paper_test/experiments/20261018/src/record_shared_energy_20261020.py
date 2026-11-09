"""Record the author's shared-GPU decision without changing historical measurements."""

import fcntl
import json
from pathlib import Path


root = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
run = root / 'experiments/20261018'
lock = (run / 'checklist_update.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX)
note = ('> 2026-10-20最新执行决定：作者要求“直接测”，GPU能量改为共享环境直接采集，'
        '记录背景进程，不因驻留CUDA进程拒收。主能量由整卡NVML功率曲线积分得到；'
        '累计计数器因与功率积分不一致仅作诊断。结果是含背景的共享整卡能量，'
        '不冒充独占SDPA能量或ASIC系统级节能倍数。\n\n')
for name in ('README.md', 'EVALUATION_PLAN_ZH.md', 'ENERGY_EVALUATION_ZH.md'):
    path = root / name
    text = path.read_text()
    if '2026-10-20最新执行决定' not in text:
        path.write_text(note + text, encoding='utf-8')
scope = run / 'evaluation_scope.json'
values = json.loads(scope.read_text())
values.update(gpu_energy_shared_environment_authorized=True,
              gpu_energy_method='NVML board-power trapezoidal integration',
              gpu_energy_counter_diagnostic_only=True,
              shared_board_energy_is_not_exclusive_sdpa_energy=True)
scope.write_text(json.dumps(values, ensure_ascii=False, indent=4) + '\n', encoding='utf-8')
