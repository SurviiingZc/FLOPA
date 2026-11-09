> 2026-10-23 范围更新：本轮 ASIC RTL 与完整多头门级能量测试最高 N=9,216。已停止 PixArt N=16,384，取消 Wan N=16,384 及两模型的 16K 门级能量测试。已有 16K GPU/整数参考数据保留为历史；其余较短长度测试继续。

> 2026-10-20功耗回读修正：原约5W受DC默认1001pF高扇出简化负载影响。同一DDC/SAIF以high_fanout_net_threshold=0重新回读，F0 d72为0.5740094W、F0 d128为0.5996562W、F2 d72为0.5556435W；匹配能量减少3.65%。这些仍为实际库pin负载、ZeroWireload/preCTS IP估计；未重综合，旧结果留存审计而不再作当前主结果。详见results中的actual_pin_load_power_audit。

> 2026-10-20最新执行决定：作者要求“直接测”，GPU能量改为共享环境直接采集，记录背景进程，不因驻留CUDA进程拒收。主能量由整卡NVML功率曲线积分得到；累计计数器因与功率积分不一致仅作诊断。结果是含背景的共享整卡能量，不冒充独占SDPA能量或ASIC系统级节能倍数。

> 2026-10-19最新决定：跨平台主比较改为每次完整多头SDPA的能量（µJ/call），原延迟保留。GPU整卡与ASIC IP边界分开标注；未测长N能量不由N256/H1功率外推。详见[ENERGY_EVALUATION_ZH.md](ENERGY_EVALUATION_ZH.md)。

> 2026-10-19 平台调整：依用户决定，主图仅比较 GPU 与 FLOPA；取消 CPU 性能测试与复测。已有 CPU 计时保留为历史，不用于论文比较。CPU 上的整数参考/误差诊断仍继续，它们不属于 CPU 性能基线。

# FLOPA：ISCAS 本轮实验清单

当前阶段：先完成现有架构的测试；数值精度优化下一轮进行。
主版本 F0 保持不变，F1/F2 使用独立对照版本。

<!-- CURRENT_TEST_CHECKLIST_BEGIN -->
更新时间：2026-10-24T22:03:41+08:00；已核验 **69/93** 项。

勾选只表示本项通过所列检查；运行中、排队、失败及待复测均保持空框。

### A. 数据与测试流程

- [x] PixArt 五个原生 N 的真实轨迹 Q/K/V；完成并核验。 <!-- task:pixart_capture -->
- [x] Wan 五个原生 N 的真实轨迹 Q/K/V；完成并核验。 <!-- task:wan_capture -->
- [x] PixArt 独立校准与冻结 scale；完成并核验。 <!-- task:pixart_calibration -->
- [x] Wan 独立校准与冻结 scale；完成并核验。 <!-- task:wan_calibration -->
- [x] PixArt N256/H1 功耗微基准独立切片校准；完成并核验。 <!-- task:pixart_power_calibration -->
- [x] Wan N256/H1 功耗微基准独立切片校准；完成并核验。 <!-- task:wan_power_calibration -->
- [x] N32 门级测试台、SAIF 窗口和功耗回读流程核验；完成并核验。 <!-- task:gate_pilot -->

### B. 主图 — PixArt-Sigma：H=16，d=72

- [x] N=1,024：完整整数参考与误差诊断；完成并核验。 <!-- task:pixart_golden_1024 -->
- [x] N=1,024：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:pixart_gpu_1024 -->
- [x] N=1,024：FLOPA 完整多头 RTL 周期与逐字节核对；完成并核验。 <!-- task:pixart_rtl_1024 -->
- [x] N=2,304：完整整数参考与误差诊断；完成并核验。 <!-- task:pixart_golden_2304 -->
- [x] N=2,304：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:pixart_gpu_2304 -->
- [x] N=2,304：FLOPA 完整多头 RTL 周期与逐字节核对；完成并核验。 <!-- task:pixart_rtl_2304 -->
- [x] N=4,096：完整整数参考与误差诊断；完成并核验。 <!-- task:pixart_golden_4096 -->
- [x] N=4,096：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:pixart_gpu_4096 -->
- [x] N=4,096：FLOPA 完整多头 RTL 周期与逐字节核对；完成并核验。 <!-- task:pixart_rtl_4096 -->
- [x] N=9,216：完整整数参考与误差诊断；完成并核验。 <!-- task:pixart_golden_9216 -->
- [x] N=9,216：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:pixart_gpu_9216 -->
- [x] N=9,216：FLOPA 完整多头 RTL 周期与逐字节核对；完成并核验。 <!-- task:pixart_rtl_9216 -->
- [x] N=16,384：完整整数参考与误差诊断；完成并核验。 <!-- task:pixart_golden_16384 -->
- [x] N=16,384：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:pixart_gpu_16384 -->
- 已取消：N=16,384：FLOPA 完整多头 RTL 周期与逐字节核对；按用户要求取消；本轮最高 N=9,216，保留已有文件。 <!-- task:pixart_rtl_16384 -->

### B. 主图 — Wan2.1：H=12，d=128

- [x] N=1,024：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_1024 -->
- [x] N=1,024：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_1024 -->
- [x] N=1,024：FLOPA 完整多头 RTL 周期与逐字节核对；完成并核验。 <!-- task:wan_rtl_1024 -->
- [x] N=2,304：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_2304 -->
- [x] N=2,304：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_2304 -->
- [x] N=2,304：FLOPA 完整多头 RTL 周期与逐字节核对；完成并核验。 <!-- task:wan_rtl_2304 -->
- [x] N=4,096：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_4096 -->
- [x] N=4,096：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_4096 -->
- [x] N=4,096：FLOPA 完整多头 RTL 周期与逐字节核对；完成并核验。 <!-- task:wan_rtl_4096 -->
- [x] N=9,216：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_9216 -->
- [x] N=9,216：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_9216 -->
- [ ] N=9,216：FLOPA 完整多头 RTL 周期与逐字节核对；RTL 回放运行中。 <!-- task:wan_rtl_9216 -->
- [x] N=16,384：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_16384 -->
- [x] N=16,384：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_16384 -->
- 已取消：N=16,384：FLOPA 完整多头 RTL 周期与逐字节核对；按用户要求取消；本轮最高 N=9,216，保留已有文件。 <!-- task:wan_rtl_16384 -->

### C. 主表 — PPA、活动功耗与匹配对照

- [x] F0 当前映射版本面积、SRAM、时钟与时序报告；完成并核验。 <!-- task:f0_ppa -->
- [x] F0 PixArt N256/H1/d72/seed301 门级活动功耗、能量与吞吐；完成并核验。 <!-- task:pixart_power -->
- [x] F0 Wan N256/H1/d128/seed301 辅助活动功耗；完成并核验。 <!-- task:wan_power -->
- [x] d72 主功耗点 seed302：采集、回放与功耗回读；完成并核验。 <!-- task:power_seed302 -->
- [x] d72 主功耗点 seed303：采集、回放与功耗回读；完成并核验。 <!-- task:power_seed303 -->
- [x] F2 关闭 PV/row-state 重叠后的 d64/72/128 与尾 tile 功能检查；完成并核验。 <!-- task:f2_function -->
- [x] F2 同库、同 PVT、同目标时钟综合与面积/时序核验；完成并核验。 <!-- task:f2_ppa -->
- [x] F2 相同 d72/N256 输入的门级功能、SAIF 与活动功耗；完成并核验。 <!-- task:f2_power -->
- [x] F0/F2 同条件周期、能量与面积对照汇总；周期降6.73%；实际pin负载IP能量降3.65%。 <!-- task:f2_comparison -->
- [ ] F1 真正 P-buffer-fed PV 的匹配设计与 RTL 实现；待启动。 <!-- task:f1_design -->
- [ ] F1 与 F0 相同输入、相同整数算术的功能核对；待启动。 <!-- task:f1_function -->
- [ ] F1 同库、同 PVT、同目标时钟综合与面积/时序核验；待启动。 <!-- task:f1_ppa -->
- [ ] F1 相同 d72/N256 输入的门级 SAIF 与活动功耗；待启动。 <!-- task:f1_power -->
- [ ] F0/F1 实际 P 读写流量、存储宏/寄存器面积及功耗分量；待启动。 <!-- task:memory_comparison -->

### D. 补充验证与论文交付

- [ ] DFoT-MCRAFT 原生 d64 真实 Q/K/V 功能与兼容性验证；待启动。 <!-- task:mcraft_function -->
- [ ] MCRAFT N256/H1/d64 辅助活动功耗；待启动。 <!-- task:mcraft_power -->
- [x] 核验 loader、片上 P/O 访问计数与论文机制结论的对应关系；完成并核验。 <!-- task:traffic_counters -->
- [ ] 结果回填精简 Excel：主图原始数据、主表及对照数据；当前实测已回填；新结果自动同步，待全量图表数据完成。 <!-- task:workbook -->
- [ ] Python 绘制两模型 GPU/FLOPA 完整多头能量主图（mJ/次），Times New Roman；待启动。 <!-- task:figure -->
- [ ] 分别生成本设计PPA表与匹配消融表，数值与已核验结果一致；待启动。 <!-- task:table -->
- [ ] 正文 Callback、结果版本及四页正文/一页参考文献排版核验；证据/计时边界已入稿；最终图表与四页检查待完成，内置编译宿主阻碍。 <!-- task:paper -->

### E. 指定时间步的全部层SDPA覆盖（N1024，步索引15，条件分支）

- [x] PixArt全部28层：真实Q/K/V采集；完成并核验。 <!-- task:pixart_layerstep_capture -->
- [x] PixArt全部28层：逐层独立校准与完整整数参考；完成并核验。 <!-- task:pixart_layerstep_golden -->
- [x] PixArt全部28层：驻留SDPA序列的累计GPU计时；完成并核验。 <!-- task:pixart_layerstep_gpu -->
- [x] PixArt全部28层：所有层RTL通过并累加实际周期；完成并核验。 <!-- task:pixart_layerstep_rtl -->
- [x] Wan全部30层：真实Q/K/V采集；完成并核验。 <!-- task:wan_layerstep_capture -->
- [x] Wan全部30层：逐层独立校准与完整整数参考；完成并核验。 <!-- task:wan_layerstep_golden -->
- [x] Wan全部30层：驻留SDPA序列的累计GPU计时；完成并核验。 <!-- task:wan_layerstep_gpu -->
- [x] Wan全部30层：所有层RTL通过并累加实际周期；完成并核验。 <!-- task:wan_layerstep_rtl -->

### F. 正式跨层覆盖（N4096，步索引15，条件分支；N1024仅流程验证）

- [x] PixArt全部28层：真实Q/K/V采集；完成并核验。 <!-- task:pixart_layerstep_n4096_capture -->
- [x] PixArt全部28层：逐层冻结校准与完整整数参考；完成并核验。 <!-- task:pixart_layerstep_n4096_golden -->
- [x] PixArt全部28层：驻留SDPA序列的累计GPU计时；完成并核验。 <!-- task:pixart_layerstep_n4096_gpu -->
- [ ] PixArt全部28层：所有层RTL通过并累加实际周期；已核验20/28层；逐层回放运行中或排队。 <!-- task:pixart_layerstep_n4096_rtl -->
- [x] Wan全部30层：真实Q/K/V采集；完成并核验。 <!-- task:wan_layerstep_n4096_capture -->
- [x] Wan全部30层：逐层冻结校准与完整整数参考；完成并核验。 <!-- task:wan_layerstep_n4096_golden -->
- [x] Wan全部30层：驻留SDPA序列的累计GPU计时；完成并核验。 <!-- task:wan_layerstep_n4096_gpu -->
- [ ] Wan全部30层：所有层RTL通过并累加实际周期；已核验15/30层；逐层回放运行中或排队。 <!-- task:wan_layerstep_n4096_rtl -->

### G. 能量主比较（完整多头SDPA，延迟数据保留）

- [x] PixArt N=1,024：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:pixart_gpu_energy_1024 -->
- [x] PixArt N=2,304：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:pixart_gpu_energy_2304 -->
- [x] PixArt N=4,096：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:pixart_gpu_energy_4096 -->
- [x] PixArt N=9,216：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:pixart_gpu_energy_9216 -->
- [x] PixArt N=16,384：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:pixart_gpu_energy_16384 -->
- [x] Wan N=1,024：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:wan_gpu_energy_1024 -->
- [x] Wan N=2,304：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:wan_gpu_energy_2304 -->
- [x] Wan N=4,096：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:wan_gpu_energy_4096 -->
- [x] Wan N=9,216：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:wan_gpu_energy_9216 -->
- [x] Wan N=16,384：GPU三窗口整卡能量/实际调用数；完成并核验（共享环境整卡能量，含背景）。 <!-- task:wan_gpu_energy_16384 -->
- [ ] PixArt N=1,024：ASIC完整多头门级活动能量；门级 SAIF 仿真运行中。 <!-- task:pixart_native_energy_1024 -->
- [ ] PixArt N=2,304：ASIC完整多头门级活动能量；待启动。 <!-- task:pixart_native_energy_2304 -->
- [ ] PixArt N=4,096：ASIC完整多头门级活动能量；待启动。 <!-- task:pixart_native_energy_4096 -->
- [ ] PixArt N=9,216：ASIC完整多头门级活动能量；待启动。 <!-- task:pixart_native_energy_9216 -->
- 已取消：PixArt N=16,384：ASIC完整多头门级活动能量；按用户要求取消；本轮最高 N=9,216，保留已有文件。 <!-- task:pixart_native_energy_16384 -->
- [ ] Wan N=1,024：ASIC完整多头门级活动能量；门级 SAIF 仿真运行中。 <!-- task:wan_native_energy_1024 -->
- [ ] Wan N=2,304：ASIC完整多头门级活动能量；待启动。 <!-- task:wan_native_energy_2304 -->
- [ ] Wan N=4,096：ASIC完整多头门级活动能量；待启动。 <!-- task:wan_native_energy_4096 -->
- [ ] Wan N=9,216：ASIC完整多头门级活动能量；待启动。 <!-- task:wan_native_energy_9216 -->
- 已取消：Wan N=16,384：ASIC完整多头门级活动能量；按用户要求取消；本轮最高 N=9,216，保留已有文件。 <!-- task:wan_native_energy_16384 -->
- [x] ASIC clock-network分组、时钟负载及SAIF映射审查；已核验1001pF简化负载，三点按实际库pin负载回读；仍为pre-CTS。 <!-- task:clock_power_audit -->
- [ ] 原形长N/全head ASIC活动能量方法与可行性核验；待核验长N活动方法；完整门级成本较高。 <!-- task:native_energy_method -->
- [ ] 主图原形完整多头ASIC能量；不由N256/H1功率外推；待测；未测保持空白，不以N256/H1替代原形算子。 <!-- task:native_energy -->

<!-- CURRENT_TEST_CHECKLIST_END -->

## 工作负载与完成标准

- 延迟单位为指定时间步、指定层的一次完整多头SDPA；GPU重复90次是同一Q/K/V的计时样本，不是30个扩散步。
- 全层覆盖补测使用N1024流程验证及N4096正式跨层点、步索引15、条件分支的全部28/30层真实Q/K/V。只有所有层回放通过才汇总实际周期；该累计SDPA不等于完整denoiser或完整采样步。
- 证据与主张对应关系见 [EVIDENCE_PROTOCOL_ZH.md](EVIDENCE_PROTOCOL_ZH.md)。

- 主图：PixArt-Sigma 与 Wan2.1，N=1024/2304/4096/9216，B=1 条件分支；16K 已退出本轮 ASIC 测试。
  比较完整多头 SDPA，排除 QKV/输出投影与 RoPE；GPU/FLOPA 使用同源真实 Q/K/V。
- GPU 为单张 RTX A6000，正式计时使用空闲设备与实际优化后端。CPU 性能对比已取消；
  既有 CPU 数据仅保留历史，CPU 上的整数/浮点参考计算仍用于功能和数值核对。
- FLOPA 延迟使用真实 RTL START 到最后输出 B 握手的周期乘 1.60ns 综合目标周期，
  明确标注非芯片实测以及理想 128-bit loader 服务模型。
- 完整整数参考和 RTL 功能检查仍覆盖所有 head、Q/K/V 行，包含 INT32 回绕行为；
  逐字节核对通过不等于数值精度通过。L2、余弦、饱和与溢出继续记录，暂不阻断本轮。
- 功耗主点为真实 Q/K/V 切片 N256/H1/d72；d128、d64 为辅助点。F0/F1/F2 必须
  使用相同输入、scale、精度、库、PVT、目标时钟和活动窗口。
- 门级功耗项只有在输出全等、SAIF 时长与周期一致、网表/DDC/输入哈希可核对、
  用户活动标注 100% 且名称冲突为零后勾选。报告 IP 内 SRAM、寄存器、ICG 与逻辑，
  排除 DRAM/主机/板卡；短微基准功耗不外推为长序列模型能量。
- F1 必须真正用缓冲供应 PV，并移除被替代的 PE 概率寄存器；F2 仅隔离 PV 与
  row-state 更新的重叠。相同输入周期、总面积、实际存储/流量和能量共同解释优势。
- 文献缺项填 NR；工艺、精度、吞吐类型、实现阶段与功耗范围不同的结果分别标明。
  当前 hold 与 min-cap 尚未物理收敛，mapped PPA 不表示物理签核完成。

## 维护方式与结果位置

清单自动项从已核验的结果状态更新；已接入本轮运行队列，不新建定时任务。
人工汇总/论文交付项完成后，在 `experiments/20261018/checklist_manual.json` 中记录
对应任务 ID、`done: true` 与 `evidence` 证据，再运行清单更新脚本。

- 详细方案：[EVALUATION_PLAN_ZH.md](EVALUATION_PLAN_ZH.md)。
- 本轮口径：[PRECISION_DEFERRAL_20261019_ZH.md](PRECISION_DEFERRAL_20261019_ZH.md)。
- 本轮状态：[LATEST_RUN_20261019_ZH.md](experiments/20261018/LATEST_RUN_20261019_ZH.md)。
- 本地结果：`experiments/20261018/jobs/`、`checklist_state.json`。
- 模型与 GPU 数据：13 服务器 `/10T/zhangcheng/flopa_evaluation_20261018`。
- F2 独立工作区：`/data/workspaces/zhangcheng/flopa_eval_f2`。
- RTL 文档：[优化计划](RTL_OPTIMIZATION_PLAN_ZH.md)、[实现报告](IMPLEMENTATION_REPORT.md)。

## 下一轮数值优化（本轮暂缓，不计入以上完成率）

- [ ] P 与 alpha 改为 32 段线性指数，验证边界与累计误差。
- [ ] 256 项倒数种子，保留二进制 exponent 至乘法后移位。
- [ ] 独立输入精度验证、回归与更新后的时序/PPA/功耗复核。

理想指数只作为软件诊断参考；下一轮数据不得直接沿用本轮版本的 PPA 与功耗。

## 2026-10-20：能量口径与初稿


- 统一主比较单位为 **mJ/次完整多头 SDPA**，排除投影、RoPE 和其余 denoiser。
- 共享 RTX A6000 的十个能量点已完成；含背景整卡能量，非进程独占能量。
- 原形完整多头 ASIC 活动能量仍待测，Excel/论文不由 N256/H1 外推。
- LaTeX 初稿已更新，保留原 Architecture，并使用一张跨栏主表和一张能量图。
- 当前仅冻结审核初稿；实验、物理签核和数值精度未闭环，不勾选终稿交付。
- 内置编译器宿主错误：Unable to find standard directories for platform；分页待核验。

## 完整多头能量补测（2026-10-20）


- PixArt N1024/H16/d72 与 Wan N1024/H12/d128 完整门级 SAIF 已启动，尚未完成。
- 验收后自动回读同一 DDC；100% 活动标注、零冲突、输出和周期核对后才接入 Excel。
- 剩余长 N 点与采样验证方法见 [完整多头能量补测](NATIVE_ENERGY_COMPLETION_ZH.md)。
- 不将启动状态勾为完成，不把 N256/H1 能量外推到完整多头曲线。

## 2026-10-21：核验与续跑

- N4096：PixArt 已核验12/28层，Wan已核验8/30层；不外推整层累计。
- SSH超时导致派发程序退出，现已恢复并加入重试；已有通过项不重跑。
- 完整多头ASIC能量仍0/10，两模型N1024门级活动继续运行。
- 详细记录见 experiments/20261018/VERIFIED_UPDATE_20261021_ZH.md。

## 2026-10-21：论文表格与测试更新


- 正文表格改为本设计PPA和匹配消融两张表；外部工作数值对比不列为强制交付。
- 两个新增真实输入seed302/303已采集并冻结原校准，N256/H1/d72门级SAIF运行中。
- 完整多头能量不使用该微基准外推；原有长任务继续运行。
- 详见 [本轮修改与测试](PAPER_REVISION_20261021_ZH.md)。

## P驻留访存实验已完成（2026-10-21）


- 两模型d72/128，N33/64/128/256共8例均通过逐字节输出、宏端口计数和P SRAM读回核验。
- N256/H1：P轨迹对照写128KiB、读128KiB；FLOPA对应P SRAM读写为0。
- 有效P分别在PV中复用72/128次；所有其它SRAM读写已一并记录，非总访存归零。
- 该对照只测流量，不是完整F1面积/功耗基线。
- 详见 [访存实验报告](TRAFFIC_STUDY_20261021_ZH.md)。

## 2026-10-22 测试续跑

本轮沿用冻结 F0 RTL、现有门级网表与 DDC；暂不改数值精度。
剩余输入已提前从 13 传至 33，126 组输入的张量与资格文件哈希核验通过。
有限队列：`experiments/20261018/src/resume_server_queue.py`。
状态与日志：`experiments/20261018/continuation_20261022/`。
它接管已在运行的仿真，继续剩余 4K 跨层、最高 9K 多头回放和门级能量点；不再启动 16K。
并发上限：每模型 4 个跨层 RTL、1 个主长度 RTL，全局 2 个门级能量作业。
空闲磁盘不足 20 GiB 时暂停新提交；失败不自动重跑。
完成后核验输出哈希，再汇总逐层周期并更新本文清单；不会自动覆盖论文 Excel。
本队列有固定实验矩阵，完成后退出，不是定时自动化。
