# 时钟门控失败经验与新策略

## 1. 目标与适用范围

本文归纳 `attention_accel_top` 前几轮时钟门控、Formality、门级 UVM、
门级 SAIF 和 hold 修复失败的原因，并定义新的可执行策略。本文只覆盖
RTL 到 mapped netlist、形式等价、门级功能、SAIF 功耗和物理时序入口；
CTS、布线和 signoff STA 仍由后端工具完成。

功耗验收必须复用基线工况：

- `fa_random_qkv_test`，`SEQ_Q=512`，`SEQ_KV=512`；
- INT8 全范围随机 Q/K/V，seed 301，无背压；
- 1.6 ns 时钟周期；
- 同一标准单元、SRAM macro、mapped DDC 和功耗分析设置；
- SAIF 来自含真实 SRAM macro 模型的门级仿真。

基线总动态功耗为 1.8932 W，其中 clock network 为 1.8325 W，占
96.29%。本轮硬目标是把 clock network dynamic 降低至少 90%，即相同
工况下不高于 **0.18325 W**。ICG 数量、gated-register 百分比或 vectorless
`report_power` 都不能代替这个指标。

## 2. 已发生的失败及根因

### 2.1 对 PE array 执行 DC 自动细粒度门控

失败网表插入约 7,789 个 ICG。Formality 初始出现 20 个
`alpha_rows_q` failing points，64x64 门级 UVM 出现 4,078 个结果错误。

根因不是“门控数量太多”本身，而是工具从独立寄存器使能推断门控时，
把同一同步事务的 payload、feature tag、valid 和 phase state 放到了不同
generated-clock 边界。RTL 中依赖同拍关系的 bundle 在门级发生错拍，
此前已经修复过的 V/O feature d 与 d+1 对齐也因此失去保证。

经验：PE 不能按单个寄存器或寄存器名称自动门控。一个 PE 的 Q/K、
max/m、sum/tag、accumulator、probability 和全部 token 必须共享同一时钟域。

### 2.2 只对白名单外围模块启用自动门控

把 fused array 和 output buffer 排除后，DC 仍生成了
`SNPS_CLOCK_GATE_HIGH_*` 包装。目标库 `CKLNQD*` 有 `TE` 引脚，但包装中的
`TE` 是局部悬空 net。门级仿真时 X 进入 generated clock，表现为全零、
high-Z、SRAM 写入错误或大量 scoreboard mismatch。

仅设置 `set_dft_signal`、修改 ICG library attribute 或增加 DFT spec view，
在没有完整 scan insertion/connect_clock_gating 流程时不能保证包装的 `TE`
被真正驱动。

经验：当前功能网表禁止 `compile_ultra -gate_clock`，禁止任何
`SNPS_CLOCK_GATE_HIGH_*`。所有功能 ICG 都由 `fa_clock_gate` 显式实例化；
`ATTN_ASIC` 下直接调用 `CKLNQD4BWP12T30P140`，功能阶段 `TE=1'b0`，不会
产生 X。scan mode 的 TE 接入属于后续 DFT 网表，不混入当前功能基线。

### 2.3 在逻辑综合中强制 SRAM hold 清零

对 top 执行 `compile -incremental_mapping -only_hold_time` 曾改变 SRAM
接口附近的映射，门级仿真出现 high-Z 和功能错误。ideal clock、zero
wireload 下的 min path 不包含真实 CTS skew、min RC 和 macro 物理位置，
即使报告数字变为零也不是可签核的 hold closure。

经验：默认 mapped netlist 只要求 setup 通过并报告 hold 风险，不对 SRAM
top 做逻辑 hold-only 重映射。能够在本阶段合理修复的 hold，只能放在
physical-aware、FF cell/FF SRAM、min-RC 的 pre-CTS 流程中；最终结论来自
post-CTS propagated clock 加 routed SPEF 的 STA，并在每次 hold repair 后
复查 SS/max-RC setup。

### 2.4 用不匹配的库做 SDF 门级仿真

综合数据库和现有 VCS 标准单元 Verilog 版本曾不一致，造成大量 SDF
annotation error。`+no_notifier` 只能防止 notifier 污染功能值，不能修复
错误的 cell arc 或真实 hold。

经验：mapped-netlist 功能和功耗使用 zero-delay gate simulation；只有拿到
与 post-CTS netlist/SDF 完全匹配的 standard-cell 和 SRAM timing model 后，
才运行 `gate-timing`。

### 2.5 以 ICG 数量代替功耗结论

早期 vectorless 报告中 mapped ICG 为零，所有 leaf clock 按全频翻转，
因此 clock network 占比异常高。后续即使能看到 ICG，也不能证明门控 enable
在真实 512x512 workload 中有效。

经验：必须检查 SAIF annotation、每个 ICG 输出 toggle、clock network
dynamic 和总 dynamic。未注释或错误层级的 SAIF 报告作废。

## 3. 新的 RTL 显式门控架构

默认 top 展开后固定为 22 个 RTL ICG，DC 自动门控固定关闭：

| 域 | 数量 | 主要负载 | enable 与排空原则 |
|---|---:|---|---|
| array control/exp | 1 | softmax FSM、row state、exp/LSE control | 完整 QK/softmax/PV busy 窗口 |
| Q skew | 1 | 32 条 row-skew payload/valid | Q input、最大深度 occupancy、末级 valid、clear |
| PV seed skew | 1 | O-seed data/tag row-skew | seed input、最大深度 occupancy、末级 valid、clear |
| K/V skew | 1 | 32 条 column-skew payload/valid | K/V input、最大深度 occupancy、末级 valid、clear |
| stripe control/delta | 4 | clear replica、phase、delta mux pipeline | 完整 array busy/drain 窗口 |
| stripe PE | 4 | 1024 个 PE 的完整状态与 token | 边界 token、prob load、最坏波前 drain counter、clear |
| stripe O bank | 4 | O SRAM clocks、read tag/valid | read request、read response、tagged write、clear |
| stripe O-seed pipe | 4 | O-old/alpha pipeline 和 8 路 multiplier | operand、两级 metadata、multiplier valid、clear |
| normalizer | 1 | normalization pipeline | issue 和 drain |
| output | 1 | output SRAM/packer/writeback state | normalize、writeback、AXI drain、clear |

四个 stripe control ICG 只驱动 phase、clear replica 和 delta mux pipeline；
大负载由三个互斥度高的局部门控域直接从根时钟承担，因此不形成级联 ICG，
也不会让 delta payload 寄存器在全局 idle 时回到根时钟常翻转。

### 3.1 不可破坏的门控规则

1. 同一事务的 payload、tag、valid、last 和 phase state 不得拆钟。
2. enable 必须在根时钟域产生，或由该 gated domain 的已寄存 valid 反馈；
   禁止由长算术数据路径产生。
3. 输入 valid 负责打开首拍。skew 使用根时钟 occupancy，PE 使用按最坏传播
   深度重装的 root-clock drain counter；排空完成后才允许关钟。
4. `!rst_n` 和同步 clear 都进入 enable。同步复位/清零状态不能依赖一个已经
   关闭的时钟；否则 RTL 透明门控正常、门级第一次使用时状态为 X。
5. SRAM 门控同时覆盖 request、response-valid 和 write-valid，不能只看请求。
6. 一个 ICG 只驱动一个完整、物理上成组的时钟域；禁止 DC 二次自动门控。
7. 功能网表所有 ICG `TE` 必须为确定常量；scan TE 只在完整 DFT 流程接入。

### 3.2 为什么不会重现之前的错拍

Q、PV seed 和 K/V skew 各自有 `max_depth+1` 的根时钟 occupancy tail。
即使输入 valid 已撤销、token 尚未到最深 delay line，门控仍保持开启。

每个 stripe 的任一 Q/K/max/m/sum 边界 token 或 probability load 都会把
`pe_drain_count_q` 重装为 `COLS + STRIPE_ROWS + 4`。该窗口覆盖最长内部波前，
同时避免上千路 PE valid 组合归约直接进入 ICG enable 的半周期路径。PE
payload、tag、valid、accumulator 和 probability 仍全部使用同一个
`pe_clk_w`。O bank 和 O-seed multiplier 是通过明确的 SRAM request/response
边界解耦的独立域，因此可以单独关钟而不改变 feature tag 的周期契约。

## 4. 综合与 Formality 约束

综合脚本不再接受 `FA_CLOCK_GATING=1`，也不执行 `-gate_clock`。发布 mapped
结果前必须满足：

- `clock_gating.rpt` 中 pre-existing ICG 恰好为 22；
- tool-inserted ICG 为 0；
- mapped netlist 不包含 `SNPS_CLOCK_GATE_HIGH_*`；
- elaboration 后立即检查并 `dont_touch` 22 个 `CKLNQD*`，禁止合并或复制改变域；
- top SRAM macro 数量仍为 480；
- setup 无违例；
- netlist、SVF 和 `run_config.rpt` 在同一次 staging run 中原子发布。

Formality 只比较与综合记录的 RTL hash 完全一致的源码；预检要求
`clock_gating=rtl_explicit`、`automatic_clock_gating=0`、22 个预期 RTL ICG，
并拒绝旧自动门控网表。`verification_clock_gate_reverse_gating` 保留，用于
处理 ICG 语义，但通过标准只有 `verification_status=PASS`，failing 和
unmatched compare points 都必须为零。

## 5. 时序与 hold 策略

### 5.1 mapped 阶段

- `make synth`：TT mapped 功能网表，要求 setup 通过；hold 报告是风险清单，
  默认不设置 `set_fix_hold`。
- 不对 SRAM top 执行逻辑 `only_hold_time` repair。
- 检查 ICG enable 到 latch、ICG output 到 leaf、跨门控域接口的 max/min path。
- generated clock 的物理 skew 尚未知，因此此阶段不能宣称最终 hold clean。

### 5.2 能在 pre-CTS 阶段修复的 hold

使用 `make prects-hold`，必须提供合并了标准单元与真实 SRAM abstract 的
Milkyway library，以及 FF/min-RC TLU+。允许在有 placement 和 min-RC 估计的
条件下插入 hold buffer；该结果仍是实现输入，不是最终 signoff。
该目标现在只在 `physical_aware=1` 时允许 hold-only incremental mapping，
不会再被 top 级旧保护条件误拒绝。

### 5.3 最终 hold authority

CTS 和 route 完成后运行 `make postcts-hold`，输入 routed netlist、对应 SDC
和 SPEF。要求所有 functional/test mode、PVT/RC/OCV view 的 setup/hold
WNS 均不小于零，并确认 ICG enable check、clock pulse width、recovery/removal
和 SRAM D/A/CEB/WEB endpoint 全部通过。然后才可对匹配的 physical SDF
执行 `make gate-timing`。

## 6. 用户执行顺序与退出条件

本轮代码更新后，当前正在运行的旧 7-ICG 综合结果不能用于验证新策略。
等旧进程自然结束并确认代码已同步后，按以下顺序执行：

```bash
make synth-config
make synth
make formality
make uvm-test UVM_SEQ_Q=64 UVM_SEQ_KV=64 UVM_SEED=301
make gate-saif GATE_SEQ_Q=64 GATE_SEQ_KV=64 \
  GATE_SIM_OUT_DIR=tb/sim/build/saif_cg_smoke_64x64_seed301
make gate-saif-power
```

`gate-saif-power` 默认就是 512x512、seed 301、1.6 ns、无背压。只有前四步
以及 64x64 mapped-gate smoke 通过才运行长 SAIF。功耗报告还必须满足：

- SAIF read/annotation 无 error，top 与主要 ICG/PE/O-bank 层级可见；
- UVM error/fatal 为零，SRAM 无 high-Z 写入；
- clock network dynamic <= 0.18325 W；
- 总动态功耗与 clock dynamic 同时报告，不能只报告百分比；
- 对比 run 使用相同 workload、seed、库、corner 和 clock period。

若 `make formality` 或 64x64 门级功能测试失败，立即停止功耗流程，不允许
通过 waiver、`+no_notifier` 或放宽 scoreboard 掩盖问题。回退到已经通过
SAIF 的 7 个粗粒度 RTL ICG 基线，再从单一完整 bundle 域逐个恢复门控。

物理流程命令：

```bash
make synth-physical \
  PHYSICAL_MW_LIB=<combined_mw_lib> \
  PHYSICAL_TLUPLUS_MAX=<max.tluplus> \
  PHYSICAL_TLUPLUS_MIN=<min.tluplus>

make prects-hold \
  PHYSICAL_MW_LIB=<combined_mw_lib> \
  PHYSICAL_TLUPLUS_MIN=<min.tluplus>

make formality CORNER=ff \
  FORMAL_NETLIST=asic/dc/work/synth/ff/hold_ff/attention_accel_top/results/attention_accel_top_mapped.v \
  FORMAL_SVF=asic/dc/work/synth/ff/hold_ff/attention_accel_top/results/attention_accel_top.svf \
  FORMAL_SYNTH_CONFIG=asic/dc/work/synth/ff/hold_ff/attention_accel_top/reports/run_config.rpt \
  FORMAL_OUT_DIR=asic/dc/work/formality/ff/hold_ff/attention_accel_top

make postcts-hold \
  POSTCTS_NETLIST=<routed.v> \
  POSTCTS_SDC=<postcts.sdc> \
  POSTCTS_SPEF=<routed.spef>

make gate-timing \
  GATE_NETLIST=<routed.v> \
  GATE_SDF=<matching_physical.sdf>
```

## 7. 对 90% 目标的工程判断

22 个域覆盖了当前最大的 clock sinks：PE 状态、O-bank/SRAM、三类 skew 和
O-seed multiplier。它消除了 QK 阶段 O/PV 时钟、softmax 阶段 skew/O 时钟、
PV 阶段 Q skew 时钟以及所有 token 排空后的无效翻转，因此是比 7 个 broad
ICG 更有针对性的架构。

但 90% 是实测门槛，不是仅凭 RTL 可以预先证明的数字。如果功能和形式验证
通过而 clock dynamic 仍高于 0.18325 W，下一轮应先按 `report_power
-hierarchy` 和各 ICG 输出 toggle 定位剩余根时钟负载，再考虑把 PE 域按
完整列组或完整 row-stripe 继续分区。不得重新启用寄存器级自动门控。
