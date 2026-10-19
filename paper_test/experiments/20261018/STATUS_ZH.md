> 2026-10-19 执行更新：用户要求先完成本轮实验，再优化数值。旧数值门槛不再阻断工程性能/功耗/对照测试，误差与溢出统计仍保留。逐字节功能、协议、哈希和功耗活动窗口仍需核验。详见 PRECISION_DEFERRAL_20261019_ZH.md 与 experiments/20261018/LATEST_RUN_20261019_ZH.md。

# 2026-10-18 实验执行记录

用户已要求按 EVALUATION_PLAN_ZH.md 开始实验。采用计划中的五个N、独立校准、
相对L2≤5%/cosine≥0.99候选工程门槛，以及短功耗微基准与原形延迟分开报告的协议。
本记录是执行状态，不表示计划中所有实验已经完成。

## 已完成

| 项目 | 结果 | 证据 |
| --- | --- | --- |
| 原RTL PV范围压力检查 | V=-128首个回绕token为513，V=127为517；逐次RTL与INT32参考一致 | results/pv_range_rtl.log |
| 宽位数算术参考 | 覆盖N=512/513/516/517/1024/16384，复现同一边界 | results/pv_range_shadow.json |
| 完整多头回放测试台，d64 | Nq=3/Nkv=5/H=2，384字节全部一致 | results/replay_smoke_d64.log |
| 完整多头回放测试台，d72 | Nq=33/Nkv=65/H=2，4752字节全部一致 | results/replay_smoke_d72.log |
| 完整多头回放测试台，d128 | Nq=31/Nkv=32/H=2，7936字节全部一致 | results/replay_smoke_d128.log |
| PixArt提示词 | 主提示词与两组独立校准提示词编码完成，CPU FP32 T5，有文件哈希 | 13服务器pixart/embeddings.json |
| PixArt真实数值资格 | N1024全16头，10/16未通过5%门槛，无输入裁剪/O溢出/输出饱和 | results/pixart_n1024_gate.json |
| 数值阶段拆分 | 在线定点递推与倒数/输出量化均有贡献；详情见修正建议 | NUMERICAL_GATE_FINDINGS_ZH.md |
| Wan真实数值资格 | N1024全12头，3/12未通过5%门槛，无O溢出 | results/wan_n1024_gate.json |
| 软件候选 | 同一诊断输入上，32段指数+256种子/保留exponent后最大误差PixArt4.30%、Wan3.93% | 两模型software_counterfactuals.json |
| 原网表门级pilot | N32/H1/d72，2304字节全等，1779周期，SAIF窗口2846.4ns | results/gate_pilot_d72_n32.json |
| 功耗流程pilot | 精确名称回读，480 SRAM宏，100%标注/0冲突；非模型PPA结果 | pilot_power_exact_reports/ |

以上回放是**合成输入的流程验证**，不能填入论文模型延迟或模型功耗结果。
压力检查证明INT32范围存在限制，不代表真实模型输入已经失败，也不代表真实输入已通过。
新测试台正确处理每个head独立16-byte对齐的输出地址，并还原为紧凑H×N×d输出检查。

## 运行中或排队

- PixArt数值放行失败，按原计划停止其后续FLOPA性能和变体综合；没有更换失败seed或门槛。
  真实采集保留已完成的N1024/2304/4096/9216；N16384主图向量尚未完成。
  独立校准已完整覆盖N1024/16384，软件counterfactual继续定位近似误差，不改变RTL。
- Wan文本组件已全部下载并SHA256验证，独立N1024/16384校准完成；
  N1024全头数值检查3/12未通过，停止其后续FLOPA性能和变体综合放行。
- 两模型均保留N1024/2304/4096/9216的真实主向量；N16384主向量尚未完成。
- 软件counterfactual已完成，不等于RTL通过或独立留出通过；等待作者确认数值修正方向。
- GPU0/1有其他计算任务。仅张量采集采用GPU0显存限额8GiB、进入前另留8GiB余量，
  不将其walltime作为性能数据。正式GPU基线仍要求空闲设备并检查竞争进程。
- 13服务器：独立数值检查worker、CPU/GPU基线worker已经排队，等待真实向量与独立校准。
  数值失败会写numerical_gate_failed.json；相应FLOPA性能/功耗放行停止，不替换失败样本。
- 本地普通后台controller会中转完整资格通过的原形向量，并在33启动实际全head回放。
  两模型均未放行，因此没有提交原形硬件性能作业；controller已自行结束。

## 入口和位置

33服务器本轮目录：

    /data/workspaces/zhangcheng/flash_attention/paper_test/experiments/20261018

13服务器本轮数据：

    /10T/zhangcheng/flopa_evaluation_20261018

13服务器脚本：

    /home/zhangcheng/DiT-FA/scripts/capture_trajectories.py
    /home/zhangcheng/DiT-FA/scripts/qualify_captures.py
    /home/zhangcheng/DiT-FA/scripts/benchmark_sdpa.py
    /home/zhangcheng/DiT-FA/scripts/run_baseline_queue.py

这是本次实验的普通后台进程队列；没有创建新的定时任务。
CPU与GPU基线可以独立于长仿真推进；F1/F2修改和新综合仍遵守数值检查前置条件。

## 环境和当前限制

- 33服务器/data约剩27GB。新测试关闭波形和FSDB；SAIF只在需要的短门级窗口采集。
- 13服务器/10T约剩3.1TB；大模型组件和张量都放这里，不复制到33的/data。
- dfot环境补装sentencepiece 0.2.2、accelerate 1.15.0、psutil 7.2.2。
  Wan保留其原生FP32模块装载要求；依赖安装日志在13服务器实验目录。
- 当前RTL、主稿Architecture和所有原图未修改；尚无新版模型性能/功耗结果入稿。
- 映射基线仍为fc9e921来源的现有DDC；625MHz是综合目标，不是物理签核或芯片实测。
- 33不能直接SSH连接13；后续已放行向量通过本地中转复制，不能假定服务器互通。

## 下一步

1. 功耗pilot已完成。后续同源门级SAIF使用精确名称，禁止套用RTL自动名称映射。
2. 完成Wan真实轨迹和独立校准集，继续短N全查询/全部head shadow。
3. 最长N先做固定查询采样、全KV/全部head的筛查。采样通过不能代替全查询放行。
4. 真正放行后才生成完整主图回放向量、长N硬件测时和匹配变体。
5. 最终入稿只用通过资格检查的真实数据；失败和未测保持明确标记。
