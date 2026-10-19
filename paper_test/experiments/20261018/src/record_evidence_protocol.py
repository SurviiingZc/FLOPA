"""Keep the README and plan aligned with the layer-level measurement contract."""

import fcntl
import json
from pathlib import Path


PAPER = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
RUN = PAPER / 'experiments/20261018'
lock = (RUN / 'checklist_update.lock').open('w')
fcntl.flock(lock, fcntl.LOCK_EX)
readme = PAPER / 'README.md'
text = readme.read_text()
note = (
    '\n- 延迟单位为指定时间步、指定层的一次完整多头SDPA；'
    'GPU重复90次是同一Q/K/V的计时样本，不是30个扩散步。\n'
    '- 全层覆盖补测使用N1024、步索引15、条件分支的全部28/30层真实Q/K/V。'
    '只有所有层回放通过才汇总实际周期；该累计SDPA不等于完整denoiser或完整采样步。\n'
    '- 证据与主张对应关系见 [EVIDENCE_PROTOCOL_ZH.md](EVIDENCE_PROTOCOL_ZH.md)。\n'
)
if '证据与主张对应关系见' not in text:
    text = text.replace('## 工作负载与完成标准\n', '## 工作负载与完成标准\n' + note)
    readme.write_text(text, encoding='utf-8')
plan = PAPER / 'EVALUATION_PLAN_ZH.md'
text = plan.read_text()
if '## 12. 单层与全层证据口径' not in text:
    text += (
        '\n## 12. 单层与全层证据口径（2026-10-19）\n\n'
        '主图是固定时间步/层的一次完整多头SDPA，不能命名为扩散时间步或完整推理延迟。'
        '固定中间层用于控制输入来源后扫描N，并不自动证明其代表所有层。\n'
        '补测N1024、步索引15、seed301、条件分支全部28/30层；逐层独立校准，'
        '使用完整head/N/d，GPU累计计时和ASIC实际周期汇总各自实测。'
        '这项验证覆盖所有self-attention层，但不覆盖其他denoiser算子或另一CFG分支。\n'
        'Fig.1模块占比、SDPA算子延迟、F0/F1/F2机制对照分别支持瓶颈、性能和机制主张；'
        '完整生成速度/质量需另做真实集成，不能由前述数据直接推断。'
        '详见EVIDENCE_PROTOCOL_ZH.md。\n'
    )
    plan.write_text(text, encoding='utf-8')
manual_path = RUN / 'checklist_manual.json'
manual = json.loads(manual_path.read_text()) if manual_path.exists() else {}
manual['workbook'] = {
    'done': False, 'status': '当前实测已回填；新结果自动同步，待全量图表数据完成',
    'evidence': ['evaluation_data.xlsx：两张基础表；待测数值为空'],
}
manual['paper'] = {
    'done': False, 'status': '证据/计时边界已入稿；最终图表与四页检查待完成，内置编译宿主阻碍',
    'evidence': ['conference_101719.tex：Introduction、Evaluation、Conclusion已统一口径'],
}
manual_path.write_text(json.dumps(manual, ensure_ascii=False, indent=4) + '\n', encoding='utf-8')
