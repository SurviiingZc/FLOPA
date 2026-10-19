# 2026-10-19：主图平台改为 GPU 与 FLOPA

依用户决定，本轮取消 CPU 延迟基线和 CPU 正式复测，历史 CPU 数据保留但不进入论文。
整数 shadow、FP32 数值参考和诊断继续在 CPU 上运行，它们用于功能核对，不是性能基线。

## 主图

- 两个模型子图：PixArt-Sigma（H16/d72）、Wan2.1（H12/d128）。
- 横轴 N=1024/2304/4096/9216/16384，纵轴完整多头 SDPA 延迟，GPU 与 FLOPA 两条线。
- GPU：RTX A6000、FP16、显存驻留 Q/K/V、优化 SDPA 后端，排除投影/RoPE/PCIe。
- FLOPA：当前 INT8 实现的完整 job 周期，乘 1.60ns 综合目标周期；保留 loader、
  KV 重读与 drain，注明理想输入服务及非芯片实测。
- 不以 FLOPA 必须快于 GPU 为验收条件。当前精度作为诊断单列，不能把不同精度与
  不同面积预算的延迟差直接解释为数据流机制收益。

## GPU 实测已完成

同一张 RTX A6000 的十个点均已完成，统一20次预热、3×30次正式测量。
已重新核对输入文件 SHA、完整 B/H/N/d、真实 kernel trace、后端选择和中位数。
十个点均选到 Flash Attention 后端；正式计时在队列确认 GPU 空闲时执行。
复核结果：13服务器 `/10T/zhangcheng/flopa_evaluation_20261018/gpu_baseline_summary.json`。
原始每次计时保留于 `baselines/cuda/<model>_p<pixels>.json`，不重复覆盖。

## 主表与机制证据保持

- 主表对比 H-FA、FSA、ITA 等 ASIC 数据，分别注明工艺、精度、存储和功耗范围。
- F0/F1 用匹配输入和实现条件比较 P 缓冲、PE 寄存器、实际读写、总面积与能量。
- F0/F2 隔离 PV/row-state 重叠的周期与能量收益。
- 不以 CPU 加速倍数作为本文优势证据；不将 GPU 整卡功耗和 ASIC IP 功耗混作节能倍数。
