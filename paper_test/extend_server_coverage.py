"""Amend existing protocol text for the formal N4096 coverage point."""

from pathlib import Path


root = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
for name in ('README.md', 'EVALUATION_PLAN_ZH.md'):
    path = root / name
    text = path.read_text()
    text = text.replace('全层覆盖补测使用N1024、步索引15',
                        '全层覆盖补测使用N1024流程验证及N4096正式跨层点、步索引15')
    text = text.replace('补测N1024、步索引15、seed301',
                        '补测N1024流程验证及N4096正式跨层点、步索引15、seed301')
    if name == 'EVALUATION_PLAN_ZH.md' and 'N4096正式跨层点对应' not in text:
        text += ('\nN4096正式跨层点对应PixArt 1024×1024图像、Wan 512×512/13帧视频；'
                 '全部28/30层使用真实轨迹输入。N1024仅作流程验证，'
                 'N4096也不代表16384所有层已测。\n')
    path.write_text(text, encoding='utf-8')
