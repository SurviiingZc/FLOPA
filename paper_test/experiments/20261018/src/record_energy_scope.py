"""Amend the approved evaluation plan and managed checklist for energy priority."""

import fcntl
import json
from pathlib import Path


root = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
run = root / 'experiments/20261018'
lock = (run / 'checklist_update.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX)
for filename in ('README.md', 'EVALUATION_PLAN_ZH.md'):
    path = root / filename
    text = path.read_text()
    note = ('> 2026-10-19最新决定：跨平台主比较改为每次完整多头SDPA的能量'
            '（µJ/call），原延迟保留。GPU整卡与ASIC IP边界分开标注；'
            '未测长N能量不由N256/H1功率外推。详见'
            '[ENERGY_EVALUATION_ZH.md](ENERGY_EVALUATION_ZH.md)。\n\n')
    if '最新决定：跨平台主比较改为' not in text:
        text = note + text
    path.write_text(text, encoding='utf-8')
scope = run / 'evaluation_scope.json'
values = json.loads(scope.read_text()) if scope.exists() else {}
values.update(primary_cross_platform_metric='gross_energy_per_complete_multihead_sdpa',
              retain_latency=True, gpu_board_and_asic_ip_boundaries_differ=True,
              allow_unvalidated_power_extrapolation=False)
scope.write_text(json.dumps(values, indent=4, ensure_ascii=False) + '\n', encoding='utf-8')
path = run / 'checklist_manual.json'
values = json.loads(path.read_text()) if path.exists() else {}
for key, status in [
        ('clock_power_audit', '待审查；当前d72点clock-network占97.22%'),
        ('native_energy_method', '待核验长N活动方法；完整门级成本较高'),
        ('native_energy', '待测；未测保持空白，不以N256/H1替代原形算子')]:
    values[key] = {'done': False, 'status': status, 'evidence': 'ENERGY_EVALUATION_ZH.md'}
path.write_text(json.dumps(values, indent=4, ensure_ascii=False) + '\n', encoding='utf-8')
