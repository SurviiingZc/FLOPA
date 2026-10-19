"""Update paper planning and README scope without changing the manuscript or RTL."""

import fcntl
from pathlib import Path


PAPER = Path('/data/workspaces/zhangcheng/flash_attention/paper_test')
RUN = PAPER / 'experiments/20261018'
NOTICE = (
    '> 2026-10-19 平台调整：依用户决定，主图仅比较 GPU 与 FLOPA；'
    '取消 CPU 性能测试与复测。已有 CPU 计时保留为历史，不用于论文比较。'
    'CPU 上的整数参考/误差诊断仍继续，它们不属于 CPU 性能基线。\n\n'
)


def main():
    lock = (RUN / 'checklist_update.lock').open('w')
    fcntl.flock(lock, fcntl.LOCK_EX)
    path = PAPER / 'EVALUATION_PLAN_ZH.md'
    text = path.read_text()
    changes = {
        'CPU/GPU 主图负责定位实际算子性能': 'GPU/FLOPA 主图负责定位实际算子性能',
        '| 模型、CPU/GPU服务器 |': '| 模型、GPU服务器 |',
        '| CPU | 双路 Xeon Gold 6133，2×20 个物理核，80 个逻辑线程；'
        '不以 Cortex-A72 作为主基线 |\n': '',
        'CPU 主基线用优化 SDPA FP32。预先固定线程候选 {1,4,8,16,20,40}，先以独立 pilot\n'
        '按 N 选择最快的合法线程/亲和性组合，再冻结正式测量配置；记录 NUMA 和物理核映射。\n'
        '不强制使用在该 CPU 上低效的 FP16，也不拿单线程慢实现作为唯一基线。\n':
        '本轮取消 CPU 性能基线与正式复测，已有 CPU 计时不进入论文对比。\n'
        'CPU 上的整数参考、FP32 数值参考和误差诊断仍用于 RTL 功能核对。\n',
        'CPU/GPU 精度与 FLOPA INT8 不同': 'GPU FP16 与 FLOPA INT8 精度不同',
        'CPU/GPU先完成输入布局与dtype准备再计时': 'GPU先完成输入布局与dtype准备再计时',
        '| CPU | 内存中完整 [1,H,N,d] SDPA 的执行、输出就绪 | '
        'QKV/输出投影、RoPE、采样循环、打包与拷贝 |\n': '',
        'CPU/GPU：独立 pilot 冻结线程/后端后，建议20次预热、3批×30次正式测量；\n'
        'GPU 用 CUDA event，CPU 用同步 wall time。过长点可预先降低重复次数并记录，\n':
        'GPU：独立 pilot 冻结最快的合格后端后，采用20次预热、3批×30次正式测量；\n'
        '使用 CUDA event，并保存真实 kernel trace。若预先调整重复数须明确记录，\n',
        '三条线固定 CPU、GPU、FLOPA': '两条线固定 GPU、FLOPA',
        'CPU/GPU主图只比时间；本轮不将CPU package/GPU整卡功耗与ASIC IP功耗并排算节能倍数。':
        'GPU/FLOPA主图只比时间；本轮不将GPU整卡功耗与ASIC IP功耗并排算节能倍数。',
        'CPU线程/NUMA/GPU后端': 'GPU UUID/后端',
        'CPU/GPU计时可先独立完成': 'GPU计时可先独立完成',
    }
    for before, after in changes.items():
        text = text.replace(before, after)
    if '2026-10-19 平台调整' not in text:
        text = NOTICE + text
    path.write_text(text, encoding='utf-8')
    for name in ('experiments/20261018/LATEST_RUN_20261019_ZH.md',
                 'PRECISION_DEFERRAL_20261019_ZH.md'):
        path = PAPER / name
        text = path.read_text()
        if '2026-10-19 平台调整' not in text:
            path.write_text(NOTICE + text, encoding='utf-8')
    path = PAPER / 'README.md'
    text = path.read_text()
    text = text.replace('CPU/GPU/FLOPA 使用同源真实 Q/K/V', 'GPU/FLOPA 使用同源真实 Q/K/V')
    text = text.replace(
        '- CPU 为双路 Xeon Gold 6133，GPU 为单张 RTX A6000。CPU 正式行等待本轮整数参考\n'
        '  计算结束后复测，原先并发期间的计时保留作初测；GPU 正式计时等待空闲条件。',
        '- GPU 为单张 RTX A6000，正式计时使用空闲设备与实际优化后端。CPU 性能对比已取消；\n'
        '  既有 CPU 数据仅保留历史，CPU 上的整数/浮点参考计算仍用于功能和数值核对。')
    text = text.replace('模型与 CPU/GPU 数据：', '模型与 GPU 数据：')
    if '2026-10-19 平台调整' not in text:
        text = NOTICE + text
    path.write_text(text, encoding='utf-8')


if __name__ == '__main__':
    main()
