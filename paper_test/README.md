> 2026-10-19 平台调整：依用户决定，主图仅比较 GPU 与 FLOPA；取消 CPU 性能测试与复测。已有 CPU 计时保留为历史，不用于论文比较。CPU 上的整数参考/误差诊断仍继续，它们不属于 CPU 性能基线。

# FLOPA：ISCAS 本轮实验清单

当前阶段：先完成现有架构的测试；数值精度优化下一轮进行。
主版本 F0 保持不变，F1/F2 使用独立对照版本。

<!-- CURRENT_TEST_CHECKLIST_BEGIN -->
更新时间：2026-10-19T16:49:29+08:00；已核验 **36/75** 项。

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
- [ ] N=2,304：FLOPA 完整多头 RTL 周期与逐字节核对；RTL 回放运行中。 <!-- task:pixart_rtl_2304 -->
- [x] N=4,096：完整整数参考与误差诊断；完成并核验。 <!-- task:pixart_golden_4096 -->
- [x] N=4,096：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:pixart_gpu_4096 -->
- [ ] N=4,096：FLOPA 完整多头 RTL 周期与逐字节核对；待启动。 <!-- task:pixart_rtl_4096 -->
- [x] N=9,216：完整整数参考与误差诊断；完成并核验。 <!-- task:pixart_golden_9216 -->
- [x] N=9,216：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:pixart_gpu_9216 -->
- [ ] N=9,216：FLOPA 完整多头 RTL 周期与逐字节核对；待启动。 <!-- task:pixart_rtl_9216 -->
- [ ] N=16,384：完整整数参考与误差诊断；整数参考生成中或排队；精度结果仅诊断。 <!-- task:pixart_golden_16384 -->
- [x] N=16,384：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:pixart_gpu_16384 -->
- [ ] N=16,384：FLOPA 完整多头 RTL 周期与逐字节核对；待启动。 <!-- task:pixart_rtl_16384 -->

### B. 主图 — Wan2.1：H=12，d=128

- [x] N=1,024：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_1024 -->
- [x] N=1,024：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_1024 -->
- [x] N=1,024：FLOPA 完整多头 RTL 周期与逐字节核对；完成并核验。 <!-- task:wan_rtl_1024 -->
- [x] N=2,304：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_2304 -->
- [x] N=2,304：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_2304 -->
- [ ] N=2,304：FLOPA 完整多头 RTL 周期与逐字节核对；RTL 回放运行中。 <!-- task:wan_rtl_2304 -->
- [x] N=4,096：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_4096 -->
- [x] N=4,096：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_4096 -->
- [ ] N=4,096：FLOPA 完整多头 RTL 周期与逐字节核对；待启动。 <!-- task:wan_rtl_4096 -->
- [x] N=9,216：完整整数参考与误差诊断；完成并核验。 <!-- task:wan_golden_9216 -->
- [x] N=9,216：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_9216 -->
- [ ] N=9,216：FLOPA 完整多头 RTL 周期与逐字节核对；待启动。 <!-- task:wan_rtl_9216 -->
- [ ] N=16,384：完整整数参考与误差诊断；整数参考生成中或排队；精度结果仅诊断。 <!-- task:wan_golden_16384 -->
- [x] N=16,384：GPU 完整多头 SDPA 正式计时；完成并核验。 <!-- task:wan_gpu_16384 -->
- [ ] N=16,384：FLOPA 完整多头 RTL 周期与逐字节核对；待启动。 <!-- task:wan_rtl_16384 -->

### C. 主表 — PPA、活动功耗与匹配对照

- [x] F0 当前映射版本面积、SRAM、时钟与时序报告；完成并核验。 <!-- task:f0_ppa -->
- [x] F0 PixArt N256/H1/d72/seed301 门级活动功耗、能量与吞吐；完成并核验。 <!-- task:pixart_power -->
- [ ] F0 Wan N256/H1/d128/seed301 辅助活动功耗；门级 SAIF 仿真运行中。 <!-- task:wan_power -->
- [ ] d72 主功耗点 seed302：采集、回放与功耗回读；待启动。 <!-- task:power_seed302 -->
- [ ] d72 主功耗点 seed303：采集、回放与功耗回读；待启动。 <!-- task:power_seed303 -->
- [x] F2 关闭 PV/row-state 重叠后的 d64/72/128 与尾 tile 功能检查；完成并核验。 <!-- task:f2_function -->
- [x] F2 同库、同 PVT、同目标时钟综合与面积/时序核验；完成并核验。 <!-- task:f2_ppa -->
- [ ] F2 相同 d72/N256 输入的门级功能、SAIF 与活动功耗；门级 SAIF 仿真运行中。 <!-- task:f2_power -->
- [ ] F0/F2 同条件周期、能量与面积对照汇总；待启动。 <!-- task:f2_comparison -->
- [ ] F1 真正 P-buffer-fed PV 的匹配设计与 RTL 实现；待启动。 <!-- task:f1_design -->
- [ ] F1 与 F0 相同输入、相同整数算术的功能核对；待启动。 <!-- task:f1_function -->
- [ ] F1 同库、同 PVT、同目标时钟综合与面积/时序核验；待启动。 <!-- task:f1_ppa -->
- [ ] F1 相同 d72/N256 输入的门级 SAIF 与活动功耗；待启动。 <!-- task:f1_power -->
- [ ] F0/F1 实际 P 读写流量、存储宏/寄存器面积及功耗分量；待启动。 <!-- task:memory_comparison -->
- [ ] 核验 H-FA-1-4、H-FA-4-4、FSA、ITA System 的 PPA/吞吐及口径；待启动。 <!-- task:external_comparison -->

### D. 补充验证与论文交付

- [ ] DFoT-MCRAFT 原生 d64 真实 Q/K/V 功能与兼容性验证；待启动。 <!-- task:mcraft_function -->
- [ ] MCRAFT N256/H1/d64 辅助活动功耗；待启动。 <!-- task:mcraft_power -->
- [ ] 核验 loader、片上 P/O 访问计数与论文机制结论的对应关系；待启动。 <!-- task:traffic_counters -->
- [ ] 结果回填精简 Excel：主图原始数据、主表及对照数据；当前实测已回填；新结果自动同步，待全量图表数据完成。 <!-- task:workbook -->
- [ ] Python 绘制两模型 GPU/FLOPA 延迟主图，Times New Roman；待启动。 <!-- task:figure -->
- [ ] 生成一张跨栏 PPA/吞吐主表，区分外部文献与同条件消融；待启动。 <!-- task:table -->
- [ ] 正文 Callback、结果版本及四页正文/一页参考文献排版核验；证据/计时边界已入稿；最终图表与四页检查待完成，内置编译宿主阻碍。 <!-- task:paper -->

### E. 指定时间步的全部层SDPA覆盖（N1024，步索引15，条件分支）

- [x] PixArt全部28层：真实Q/K/V采集；完成并核验。 <!-- task:pixart_layerstep_capture -->
- [x] PixArt全部28层：逐层独立校准与完整整数参考；完成并核验。 <!-- task:pixart_layerstep_golden -->
- [ ] PixArt全部28层：驻留SDPA序列的累计GPU计时；等待空闲GPU或排队。 <!-- task:pixart_layerstep_gpu -->
- [ ] PixArt全部28层：所有层RTL通过并累加实际周期；已核验0/28层；逐层回放运行中或排队。 <!-- task:pixart_layerstep_rtl -->
- [x] Wan全部30层：真实Q/K/V采集；完成并核验。 <!-- task:wan_layerstep_capture -->
- [ ] Wan全部30层：逐层独立校准与完整整数参考；全部层整数参考生成中。 <!-- task:wan_layerstep_golden -->
- [ ] Wan全部30层：驻留SDPA序列的累计GPU计时；等待空闲GPU或排队。 <!-- task:wan_layerstep_gpu -->
- [ ] Wan全部30层：所有层RTL通过并累加实际周期；已核验0/30层；逐层回放运行中或排队。 <!-- task:wan_layerstep_rtl -->

### F. 正式跨层覆盖（N4096，步索引15，条件分支；N1024仅流程验证）

- [x] PixArt全部28层：真实Q/K/V采集；完成并核验。 <!-- task:pixart_layerstep_n4096_capture -->
- [ ] PixArt全部28层：逐层冻结校准与完整整数参考；全部层整数参考生成中。 <!-- task:pixart_layerstep_n4096_golden -->
- [ ] PixArt全部28层：驻留SDPA序列的累计GPU计时；等待空闲GPU或排队。 <!-- task:pixart_layerstep_n4096_gpu -->
- [ ] PixArt全部28层：所有层RTL通过并累加实际周期；已核验0/28层；逐层回放运行中或排队。 <!-- task:pixart_layerstep_n4096_rtl -->
- [x] Wan全部30层：真实Q/K/V采集；完成并核验。 <!-- task:wan_layerstep_n4096_capture -->
- [ ] Wan全部30层：逐层冻结校准与完整整数参考；全部层整数参考生成中。 <!-- task:wan_layerstep_n4096_golden -->
- [ ] Wan全部30层：驻留SDPA序列的累计GPU计时；等待空闲GPU或排队。 <!-- task:wan_layerstep_n4096_gpu -->
- [ ] Wan全部30层：所有层RTL通过并累加实际周期；已核验0/30层；逐层回放运行中或排队。 <!-- task:wan_layerstep_n4096_rtl -->

<!-- CURRENT_TEST_CHECKLIST_END -->

## 工作负载与完成标准

- 延迟单位为指定时间步、指定层的一次完整多头SDPA；GPU重复90次是同一Q/K/V的计时样本，不是30个扩散步。
- 全层覆盖补测使用N1024流程验证及N4096正式跨层点、步索引15、条件分支的全部28/30层真实Q/K/V。只有所有层回放通过才汇总实际周期；该累计SDPA不等于完整denoiser或完整采样步。
- 证据与主张对应关系见 [EVIDENCE_PROTOCOL_ZH.md](EVIDENCE_PROTOCOL_ZH.md)。

- 主图：PixArt-Sigma 与 Wan2.1，N=1024/2304/4096/9216/16384，B=1 条件分支。
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
