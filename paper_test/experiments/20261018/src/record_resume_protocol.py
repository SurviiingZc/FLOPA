"""Record the user's precision deferral without rewriting historical results."""

from pathlib import Path


root = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
notice = (
    '> 2026-10-19 执行更新：用户要求先完成本轮实验，再优化数值。'
    '旧数值门槛不再阻断工程性能/功耗/对照测试，误差与溢出统计仍保留。'
    '逐字节功能、协议、哈希和功耗活动窗口仍需核验。'
    '详见 PRECISION_DEFERRAL_20261019_ZH.md 与 '
    'experiments/20261018/LATEST_RUN_20261019_ZH.md。\n\n'
)
for path in (root / 'README.md', root / 'EVALUATION_PLAN_ZH.md',
             root / 'experiments/20261018/STATUS_ZH.md'):
    previous = path.read_text(encoding='utf-8')
    if '2026-10-19 执行更新' not in previous:
        path.write_text(notice + previous, encoding='utf-8')
