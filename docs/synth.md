# Synthesis Debug and Optimization Log

本文档集中记录综合、物理综合和布局布线暴露的问题。后续每轮综合均在此追加基线、根因、修改、复测结果和状态，避免问题分散在日志或聊天记录中。

## 1. Frequency policy

- FPGA 与 ASIC 使用同一数据流 RTL，但时钟实现不同。FPGA 细粒度低功耗依赖寄存器、DSP、BRAM 和 URAM 的 `CE/EN`，禁止用 LUT 生成 `clk & en`；只有整域长时间空闲时才考虑 `BUFGCE/BUFHCE`。
- ASIC 使用 28 nm 标准单元库的无毛刺 ICG，当前 RTL wrapper 绑定 `CKLNQD4BWP12T30P140`。控制/AXI 保持常开，fused array 按控制与 stripe 分层门控，normalizer 和 output buffer 独立门控。
- ASIC 第一阶段目标设为 **400 MHz（2.5 ns）**。这是综合优化目标，不是流片承诺；最终频率必须同时满足 SS setup、FF/fast hold、RC、拥塞、CTS、IR-drop 和 OCV。
- 频率上限由扫描得到。TT 扫描用于观察逻辑上限，SS 加物理感知结果决定可承诺频率。

## 2. 2026-07-20 baseline: TT logical synthesis

配置：TT 0.9 V/25 C，周期 3.2 ns，ideal clock，ZeroWireload，480 个 `uhdsp_256x8m4s` SRAM macro。

| Item | Result | Assessment |
| --- | ---: | --- |
| Setup WNS / TNS | +0.2608 ns / 0 | 仅零线长 TT 通过，裕量不足 |
| Critical path | 2.8259 ns, 88 levels | normalizer 64-bit rounding carry chain |
| Hold WNS / TNS | -0.1739 ns / -11711.93 ns | 259234 条违例，最差为寄存器到 SRAM D |
| Total cell area | 3150819.90 um2 | 不含互连和宏 halo |
| Leaf / sequential cells | 1751361 / 255434 | 时钟负载很大 |
| Buffer/inverter | 232013 | 控制、复位和阵列分发压力明显 |
| Fused-array area | 2765317.29 um2, 87.8% | 1024 PE 为面积主体 |
| Macro count / area | 480 / 656746.70 um2 | 数量正确，组织利用率低 |
| Vectorless total power | 333.0011 mW | 不可作为最终功耗 |
| Clock internal power | 316.7454 mW, 95.12% | 说明必须进行分层门控 |
| Max-fanout violations | 4339 | 多数为 19 > 16 的局部网络；另有 9 个高扇出网络按 1000 估算 |
| Check-design | 31072 unconnected ports, 5185 unloaded hierarchy pins | PE 通用接口携带大量无效信号 |

### Baseline conclusions

1. 原 32768-bit score tile 总线已经消除，当前数据移动以 PE 邻接连接和 stripe 边界为主；现阶段主要物理风险转为时钟、复位、控制分发和三角 skew 寄存器网络。
2. 3.2 ns setup 通过不能证明 312.5 MHz 可布局布线。关键路径没有计入互连，且顶层尚无 SS 结果。
3. 绝对功耗不可信：报告采用 low-effort vectorless activity，并有 `PWR-428` SRAM black-box output 未标注；但 25.5 万时序单元的时钟脚功耗是明确的结构问题。
4. 旧 `pe_timing` 结果显示 PE MAC 并非当前关键路径，但必须用最终 `fsa_fused_pe` 重新跑 TT/SS 才能作为正式结论。

## 3. Round-1 optimization

### S1: Normalizer rounding path - implemented, pending synthesis

原逻辑先构造 `1 << (shift-1)`，再与 64-bit product 相加/相减，综合成约 60 级全加器进位链；负数路径还会把本来整除的结果继续向负方向偏置。

修改后先执行算术右移，使用 guard/sticky 判定 round-to-nearest、ties-away-from-zero，仅对 9-bit INT8 饱和候选执行 `+1`。流水级数和 valid/tag 延迟不变，删除 64-bit rounding-bias carry chain。

`scale_requant_unit` 同步采用 guard/sticky，并在移位后把可恢复范围限制到 18 bit，再叠加 signed 16-bit zero point，避免 normalizer 修复后该模块成为新的宽进位关键路径。

复测要求：normalizer 最差路径不得再出现连续 64-bit `FA1` carry chain；单级组合逻辑建议在 SS 下不超过 2.1 ns，为 2.5 ns 周期预留时钟、OCV 和布线预算。

### S2: Hierarchical clock gating - implemented, pending power synthesis

- ASIC：一个 fused-array control/exp ICG 加每 stripe 一个 ICG；normalizer 与 output buffer 各有独立 ICG。
- 门控 enable 覆盖 start、busy、pipeline drain、同步 clear 和 normalization/writeback，不能只检测单周期 valid。
- FPGA：`fa_clock_gate` 直接透传根时钟，不产生 fabric-gated clock；现有 valid-qualified payload 更新继续推断 CE。
- datapath 异步复位缩减尚未执行。下一阶段应只复位 valid/control，避免 reset 树覆盖全部 skew payload。

功耗复测必须回标实际 prefill SAIF/VCD；检查 `report_clock_gating`、ICG 数量、各 gated-clock activity 和 clock power 占比。

### S3: SRAM hold - corrected in Round 3, pending physical verification

- setup uncertainty 与 hold uncertainty 分离，默认分别为 0.100 ns 和 0.020 ns。
- 对 `core_clk` 启用 `set_fix_hold`。
- Round-1 曾对 SRAM 非 CLK 输入设置默认 0.200 ns minimum path；Round-3 已删除
  该默认值，只保留 Liberty hold、hold uncertainty 和 `set_fix_hold`。
- 不在 RTL 中添加伪延迟。最终 hold 只能在 CTS 后用 propagated clock 修复和签核。

复测要求：逻辑综合 hold WNS 不小于 0；物理阶段分别在 fast cell/fast RC 和实际 SRAM fast corner 下检查，并报告 SRAM D/A/control 三类 endpoint。

### S4: Invalid interface cleanup - implemented, RTL check passed

已删除全阵列无消费者的 `prob_o`、`mac_valid_o`、WS-PV `sum_last` 链、PV `array_last` 链、stripe Q tail 状态输出、stripe `m_done_valid_o` 和未接到顶层的 row-state debug read 接口。Q/K last 仍保留，因为 QK 完成和 rowmax 发射需要其在脉动阵列中传播。

原先悬空的 qk/PV/controller/softmax/output busy 端口接入顶层门控条件。复测后按新的 `check_design.rpt` 继续区分：边界实例天然未用的端口、常量传播产生的告警、可以继续删除的接口。

## 4. SRAM reorganization proposal - deferred

当前 480 个 256x8 macro 提供 983040 bit，逻辑有效数据约 180224 bit，总 bit 利用率约 18.3%。QKV 和 output buffer 约 25%，persistent O-bank 约 12.5%；O-bank 使用 256 个宏，是首先需要重组的对象。

FPGA 初版保持当前逻辑映射并由 BRAM/URAM 推断，不在本轮改变 bank 时序。ASIC 后续方案按优先级评估：

1. 选择更浅、更宽、支持 byte write 的 SRAM，使深度匹配 64-feature 或 32-feature group。
2. 将同 stripe 多个 row 打包到宽字，利用 byte mask 接收逐 row 写回；读取一个 feature 时一次返回所有 row。
3. 若单端口读写冲突阻止合并，优先比较双口宏、偶奇 feature banking、两倍频 memory clock，而不是简单复制大宏。
4. 更换更大宏前必须同时计算 bit utilization、并行端口数、同周期冲突、宏数量、布线宽度和 leakage；只看总容量会使利用率更差。

## 5. When to replace `*` with a multiplier module

当前不需要替换。综合器会将普通 `*` 映射为 DesignWare 乘法器，FPGA 会在位宽和流水结构允许时推断 DSP；现有结果也表明 top critical path 不在 PE MAC。

只有出现以下情况才引入显式 multiplier wrapper、`DW_mult_pipe`、FPGA DSP primitive 或定制 Booth/Wallace macro：

1. 最终 RTL 的物理感知综合证明 multiplier 是 WNS endpoint，且 retiming/增加流水级仍不能满足目标。
2. 必须固定乘法器 latency、DSP cascade、operand isolation 或多周期协议，综合推断结果不稳定。
3. FPGA 报告确认乘法落入 LUT，或 ASIC 映射成面积/功耗异常的宽乘法器。
4. 使用已完成 PVT、LEC、DFT 和版图验证的硬宏；否则显式模块通常只会降低移植性和资源共享机会。

每轮都应检查 `report_resources` 和 multiplier path，而不是根据 RTL 中是否出现 `*` 做替换。

## 6. Synthesis commands

```bash
# 400 MHz logical synthesis target
make synth-system CORNER=tt CLOCK_PERIOD=2.5
make synth-system CORNER=ss CLOCK_PERIOD=2.5

# Fmax sweep; each point keeps reports only, not multi-GB SDF/netlists
make synth-frequency-sweep CORNER=tt
make synth-frequency-sweep CORNER=ss \
  FREQ_SWEEP_PERIODS="3.0 2.8 2.6 2.5 2.4 2.3"

# Focused final PE timing
make pe-timing CORNER=tt CLOCK_PERIOD=2.5
make pe-timing CORNER=ss CLOCK_PERIOD=2.5

# DC Graphical physical-aware synthesis
make synth-physical CORNER=ss CLOCK_PERIOD=2.5 \
  FA_MW_LIB=/path/to/combined_design_mw \
  FA_TLUPLUS_MAX=/path/to/max.tluplus \
  FA_TLUPLUS_MIN=/path/to/min.tluplus \
  FA_TLUPLUS_MAP=/path/to/tech2itf.map
```

频率扫描结果写入 `asic/dc/work/frequency_sweep/<corner>/summary.csv`，最高非负 setup WNS 点写入 `best_passing.csv`。物理综合要求 Milkyway 库同时包含 standard-cell FRAM 和 SRAM abstract；仅有逻辑 `.db` 或仅有标准单元 FRAM 时不得将结果视为物理感知结论。

## 7. Round-1 verification

- `make rtl-check CORNER=tt` 在 2.5 ns 约束下完成 analyze/elaborate/link，480 个 `uhdsp_256x8m4s` 均正确解析，SRAM 非时钟输入的 minimum-delay 约束已实际执行，DC 日志无 `Error`。
- `tb_online_normalizer`、`tb_scale_requant_unit`、`tb_fsa_stripe`、`tb_output_buffer`、`tb_fsa_fused_array` 和顶层 `tb_attention_accel_top` 均通过 VCS 仿真，并按 TB 默认行为生成 FSDB；顶层用例在 1334 cycles 完成。
- shell 脚本通过 `bash -n`；`synth-frequency-sweep` 与 `synth-physical` 的 Makefile 命令展开正确。
- 当前 RTL elaboration 仍有 51 条 `VER-318` signed/unsigned 转换告警；未编译 GTECH 的 `LINT-1` dead-cell 告警不能替代 mapped `check_design`，两类问题继续保留到下一次完整综合按路径清理。
- 本轮按要求没有运行完整 `compile_ultra`、频率扫描或物理感知综合，因此 400 MHz 是否通过、时钟功耗下降幅度及 SRAM hold 裕量必须以用户下一轮报告为准。

## 8. 2026-07-20 round-2: TT 400 MHz logical synthesis

配置：TT 0.9 V/25 C，周期 2.5 ns，setup/hold uncertainty 分别为 0.100/0.020 ns，ideal clock，ZeroWireload，480 个 SRAM macro。频率扫描仍在运行，本节只分析已完成的 system 报告。

| Item | Baseline, 3.2 ns | Round-2, 2.5 ns | Assessment |
| --- | ---: | ---: | --- |
| Setup WNS / TNS | +0.2608 ns / 0 | +0.0067 ns / 0 | TT 400 MHz 仅勉强通过，没有布线、SS、OCV 裕量 |
| Critical path | 2.8259 ns, 88 levels | about 2.38 ns, 76 levels | rounding carry chain 已消除；瓶颈转移到 normalizer 的 scale multiplier |
| Hold WNS / TNS | -0.1739 / -11711.93 ns | -0.2939 / -1820.17 ns | 违例数量大幅减少，但 0.2 ns min-delay 与 macro hold 被重复叠加 |
| Hold violations | 259234 | 7424 | 减少 97.1%，剩余主要为 register-to-SRAM D |
| Total cell area | 3150819.90 um2 | 3144017.58 um2 | 降低 0.22%；更高频率下基本持平 |
| Fused-array area | 2765317.29 um2 | 2760406.31 um2 | 仍占 87.8%，PE 数据宽度是下一轮主要面积机会 |
| Sequential cells including macros | 255434 | 254541 | 减少约 0.35% |
| Vectorless dynamic power | about 333.00 mW | 8.5702 mW | 工具值降低 97.4%，但没有真实 activity，不能作为芯片功耗结论 |
| Clock internal power | 316.7454 mW | 5.5262 mW | 7 个 ICG 均映射成功；真实节省必须用 SAIF 复核 |
| Max-fanout violations | 4339 | 4350 | 当前违例最大 fanout 仅 19，主要是全局限制 16 过严，不是超大扇出灾难 |
| Unconnected ports | 31072 | 12094 | 减少 61.1%，剩余 8971 条来自通用 PE 接口 |
| Unloaded hierarchy pins | 5185 | 3936 | 减少 24.1%，主要是阵列边界、常量位和 last sideband |

### 8.1 Timing conclusion

前 20 条 setup 路径全部从合并后的 `scale_mant_q` 寄存器到各 lane 的 `scale_product_q[63:62]`，最差 slack 为 +0.0067 ns。原 64-bit rounding-bias carry chain 不再出现，说明上一轮舍入重构有效；新瓶颈是：

```text
norm_product_q[63:0] >>> 15  x  signed scale_mant_q[15:0]
```

该表达式让 DC 实现接近 64x16 的单周期有符号乘法。按当前数值格式，reciprocal 小于 2^30，signed ACC 幅值不超过 2^31，乘积右移 15 后幅值不超过 2^46，因此可以先注册为保守的 signed 48-bit normalized operand，再执行 48x16 乘法；修改前必须用随机和边界向量证明位宽界限与饱和结果等价。

若缩窄后 TT setup 裕量仍小于 0.20 ns，或 SS 2.5 ns 不通过，则第二步引入两级乘法 wrapper：ASIC 使用可控 latency 的 pipelined DesignWare 实现，FPGA 使用可推断 DSP pipeline 的等价分支。该操作增加 1 个 normalizer startup cycle，但保持每周期一组 8-row 输出，基本不影响长序列吞吐。现在已经满足“乘法器成为重复关键路径”这一显式模块化条件。

### 8.2 PE width and multiplier opportunity

Round-2 RTL 中 Q/K/V cache 元素实际为 signed INT8，但当时
`ATTN_ARRAY_DATA_W` 为 16，QK/PV engine 先把每个 INT8 sign-extend 到 16 bit，
再通过阵列寄存和端口传输。分析结论是扩展只应发生在乘法器入口，不应让阵列
存储和连线永久翻倍；该结论已在 Round-3 RTL 实施。

Round-3 采用以下独立位宽：

- `QKV_W=8`：Q/K/V 阵列寄存、水平/垂直链和 engine 接口使用 8 bit。
- `PROB_W=16`：P 继续保留 unsigned Q1.15，不与 QKV 宽度绑定。
- 共享乘法器 A 端为 17 bit：Q 在 QK 模式符号扩展，P 在 PV 模式零扩展。
- 共享乘法器 B 端为 9 bit：K/V signed INT8 只扩展一位。
- 物理乘法器由当前近似 17x17 缩为 17x9；QK 取精确 16-bit product，PV 取精确 24-bit product，再符号扩展进入 32-bit accumulator。

该方案同时把每组 32-lane `qk_rows/qk_cols/pv_cols` 从 512 bit 降至 256 bit，并减少 1024 个 PE 的 Q/K 数据寄存器、乘法器部分积和常量扩展网络。它保持 QK 与 WS-PV 算法和 cycle schedule 不变，预期面积/功耗收益显著高于继续微调顶层控制。

### 8.3 Hold constraint correction

当前最差 hold path 为 tile-cache write register 到 SRAM `D`，data arrival 为 0.0469 ns。报告把 0.200 ns `set_min_delay`、0.020 ns hold uncertainty 和 SRAM Liberty 自带的 0.1208 ns hold requirement 相加为 0.3408 ns，因此 WNS 为 -0.2939 ns。这里的 `set_min_delay` 不是 hold margin，而是额外的最小数据路径要求，当前默认值造成重复保守。

下一轮将 SRAM input min-delay 默认改为 0，保留 macro Liberty hold、0.020 ns hold uncertainty 和 `set_fix_hold`。逻辑综合只观察早期风险，不为 ideal-clock/zero-wire 结果插入数千个无意义 buffer。正式修复必须在 fast cell、fast SRAM、min-RC、propagated clock 的 CTS 后场景完成，并分别报告 SRAM D、A、CE/WEB endpoint；如果确实需要额外最短路径规范，再由物理分析反推非零 margin。

### 8.4 Power interpretation

Mapped netlist 中已确认 7 个 `CKLNQD4BWP12T30P140`：array control/exp 1 个、4 个 stripe、normalizer 1 个、output buffer 1 个。clock-network internal power 从 316.75 mW 降到 5.53 mW，说明 ICG 被识别并参与 vectorless 传播；但它仍占本轮 8.57 mW dynamic power 的约 64.5%。当前还有 `PWR-428`，SRAM black-box output 未标注，且未读取真实 switching activity。

下一轮功耗流程必须增加：从顶层 prefill TB 导出 SAIF，`read_saif -strip_path tb_attention_accel_top/dut`，报告 annotation coverage、`report_clock_gating`、hierarchical power 和各 gated-clock activity。至少使用 idle、Re10K prefill、LLM prefill 三个 profile；decode/GQA 在第二阶段加入。没有 SAIF 前只比较结构趋势，不发布绝对 mW 或节能百分比。

### 8.5 Check-design classification

Round-2 仍有 12094 个 `LINT-28`、3936 个 `LINT-60` 和 48 个 `LINT-33`。处理原则如下：

1. P1：删除 PE 中二维传播但最终只消费右下角结果的 `q_last/k_last/mac_last` 网络；用阵列外独立 1-D sideband delay 或经过证明的固定 latency 产生 `qk_last_o`。预计删除约 3072 个 PE sideband 寄存器及大量层级端口。
2. P1：执行 8-bit QKV 数据通路重构，消除 sign-extension 常量位造成的 `qk_rows/qk_cols/pv_cols`、Q/K data 端口告警。
3. P2：`max_data_i` 在第一列由常量 seed 优化、`prob_data_i[15]` 因 P 非负而为常量、末行/末列输出无消费者，这些告警不对应实际悬空逻辑；在结构改动后建立精确 waiver，不为清零报告制造边界 wrapper。
4. P2：AXI-Lite 地址高位未译码属于协议宽度与局部地址空间的正常差异，不能把 32-bit AXI 地址接口缩窄；只 waiver 未使用高位。
5. P2：未实现的软件配置输出只有在确认不会支持对应功能后才能删除，否则标记为 reserved。`LINT-33` 表示同一 net 连接同一子模块多个 pin，不是 multiple-driver，逐项确认后 waiver。

### 8.6 Fanout and reset

4350 个 max-fanout 违例的实际 fanout 都不超过 19，大多数只是比全局阈值 16 多 1--3 个负载。下一轮不为此重构数据流：先比较 `FA_MAX_FANOUT=16/24/32` 的 buffer 数、面积和 WNS，以 max transition/capacitance 及物理拥塞作为最终标准。`check_timing` 报告的 16 个 high-fanout net 需要新增按 net 排序的 fanout 报告，区分 root clock、gated clock、reset 和真实控制网。

约 25.4 万时序单元仍使 reset 网络成为潜在物理风险。完成 P0/P1 功能修改后，只保留 state、valid、tag/计数器等控制寄存器复位；被 valid 保护的 Q/K/V、partial sum、skew payload 和乘法中间数据取消异步复位。该改动必须用 reset 后 X-propagation 和门级仿真证明无未初始化数据被消费。

### 8.7 Ordered round-3 plan

| Priority | Change | Expected result | Required regression |
| --- | --- | --- | --- |
| P0 | QKV 16-to-8 bit array path; 17x9 shared PE multiplier | 大幅降低 1024 PE 面积、功耗和 routing width | QK/PV boundary vectors, full top TB, LEC |
| P0 | Normalizer operand bound to 48 bit; if needed two-stage multiplier | TT/SS 400 MHz 留出至少 0.20 ns logical margin | rounding/saturation exhaustive edges, tag/latency TB |
| P0 | Remove default 0.2 ns SRAM min-delay double count | 得到可解释的 logical hold report | D/A/control endpoint reports at TT and fast corner |
| P1 | Replace 2-D last network with 1-D completion sideband | 删除约 3K sideband FF and ports | all array sizes, QK drain latency assertions |
| P1 | SAIF power and clock-gating reports | 得到可复现 active/idle power | activity coverage and three workload profiles |
| P1 | Remove reset from valid-qualified payload | 降低 reset tree、cell area and routing pressure | reset/X-prop, scan/DFT review |
| P2 | Fanout threshold sweep and report cleanup/waivers | 减少无意义 buffer 与噪声 | 16/24/32 QoR comparison |
| Deferred | SRAM organization | FPGA 初版不变；ASIC floorplan 前处理 | port-conflict and macro-utilization study |

Round-3 完成后先跑 module/top simulation 和 TT/SS 2.5 ns system synthesis，再根据当前频率扫描结果缩小扫描区间；只有 physical-aware SS 结果也满足 setup、且 fast/min-RC hold 可修复时，才把 400 MHz 作为 ASIC 实现目标。

## 9. Exit criteria and update template

进入 FPGA 初版测试前：RTL/module TB 通过，Vivado report_timing/report_methodology 无未约束路径，实际可用频率按板上实现结果设定，不强求与 ASIC 相同。

进入 ASIC floorplan 前：TT/SS 逻辑综合、频率扫描、check_design、SAIF 功耗和最终 PE 独立报告齐全；`VER-318` 等 signed/unsigned 告警清零或逐条豁免。

进入 CTS 前：完成 SRAM 重组选择、宏 floorplan、ICG 分区、reset strategy 和 scan plan。流片签核要求全 PVT/RC/OCV setup/hold、IR-drop、EM、DRC/LVS 和门级等价验证通过。

后续问题按以下格式追加：日期与 commit、corner/period/activity、关键指标、问题编号和优先级、路径起止点、根因、修改、回归、状态、下一步。

## 10. 2026-07-21 round-3 implementation status

本轮按 Round-2 报告实施了以下修改，但尚未用新的完整 `compile_ultra` 结果替换
Round-2 数字：

1. Q/K/V 阵列通路由 16 bit 恢复为 native signed INT8，PE 共享乘法器为 17x9；
   QK/PV product 分别保持精确 16/24 bit。
2. normalizer 把移位后的中间值做 sign-extension 检查并缩为 signed 48 bit，再做
   48x16 scale multiply。仅当新 TT 裕量小于 0.20 ns 或 SS 2.5 ns 不通过时，才启用
   固定延迟 two-stage multiplier wrapper。
3. 默认 SRAM input min-delay 已由 0.2 ns 改为 0；Liberty hold、hold uncertainty
   和 `set_fix_hold` 保留。正式 hold 修复留给 fast SRAM/cell、min-RC、CTS
   propagated-clock 场景。
4. PE 内二维 `q_last/k_last/mac_last` 已删除，改为阵列外 `ROWS+COLS` 一维
   completion sideband 和固定 taps。
5. valid 保护的主要 datapath payload 已取消异步 reset；控制状态、valid、计数器、
   必要 tag 和外部可见状态保留 reset。
6. 同类审计额外把 old-O rescale 从意外宽乘法收敛为 signed 32x17，把
   `old_l*alpha` 收敛为 unsigned 32x16。
7. 对所有 mixed-width `*` 显式建立完整 product context，消除 Verilog 乘积高位
   截断歧义；PE、requant、normalizer、O-rescale 和 LSE 的 multiplier
   width-mismatch lint 已清零。综合时仍需确认重复 sign/zero bits 被折叠为有效
   17x9、48x16 等资源，而不是保留成表面扩展位宽。

现有 23 个 module/integration regression 全部通过，top 仍为 1334 cycles；新增 PE
directed TB 覆盖 signed INT8 和 signed V 的极值，`HEAD_DIM=128` 顶层重新
elaborate 通过。频率扫描在 RTL 修改期间已经
启动，其结果跨越不同源码版本，不得用于本轮 Fmax、面积或功耗结论。必须以固定
source hash 重新运行 TT/SS sweep。

The status above is the historical Round-3 checkpoint. The current pre-synthesis
baseline is 24 active regressions and 1348 top cycles after implementing the
timing pipelines documented in Section 11.7.

### 10.1 New synthesis acceptance criteria

| Check | Acceptance |
| --- | --- |
| TT 2.5 ns setup | WNS >= 0.20 ns；否则启用两级 normalizer multiplier |
| SS 2.5 ns setup | WNS >= 0；否则启用两级 multiplier 并重新扫描 |
| PE resources | 确认每 PE 只有一处 17x9 phase-shared multiply，不重复 QK/PV hardware |
| Array area/power | 与 Round-2 比较 fused-array area、sequential count 和 multiplier power |
| Completion network | `q_last/k_last/mac_last` 不再出现在 mapped hierarchy |
| Reset | 按 async-reset cell count、reset fanout 和 X-prop regression 验收 |
| Hold | 逻辑报告不再含默认 0.2 ns requirement；最终只看 fast/min-RC CTS 场景 |
| Fanout | 分别用 16/24/32 阈值比较 QoR，不为 fanout=19 预先改 RTL |
| Power | UVM 后对 idle、Re10K prefill、LLM prefill 报告 SAIF coverage 和 gated-clock activity |

SAIF 的 workload、文件命名、回标路径、报告和验收项见
`asic/docs/saif_power_plan.md`。在 coverage 达标前，只报告结构性面积/门控趋势，
不发布绝对 mW 或节能百分比。

## 11. 2026-07-21 frequency-1p9ns report audit and optimization plan

### 11.1 Report validity and headline result

`frequency_1p9ns` 使用了 Round-3 RTL，但继承了扫描启动时的旧环境：

```text
corner                  = TT 0.9 V / 25 C
clock period            = 1.900 ns
setup/hold uncertainty  = 0.100 / 0.020 ns
wire load               = ZeroWireload
clock                    = ideal
FA_SRAM_INPUT_MIN_DELAY  = 0.200 ns   # stale; current default is zero
```

因此该点不能表述为“1.9 ns 有裕量通过”。最差 setup data arrival 为
`1.7909 ns`，required time 也为 `1.7909 ns`，WNS 精确为 `0.0000 ns`；summary
CSV 从 `qor.rpt` 只保留两位小数，也会隐藏小于 0.01 ns 的裕量。

| Item | Result | Assessment |
| --- | ---: | --- |
| Setup WNS/TNS | 0.0000 / 0 ns | 压线通过，没有 physical/OCV margin |
| Hold WNS/TNS | -0.2941 / -1831.57 ns | 7424 paths；旧 0.2 ns min-delay 是主因之一 |
| Cell area | 2491044.77 um2 | Round-3 width/reset/sideband 优化已显著降低面积 |
| Sequential cells | 228730 | reset/sideband FF 数量下降，但阵列仍是主体 |
| Buffer/inverter cells | 233766 | 高频约束和大阵列控制/数据网仍有较大 buffering 压力 |
| High-fanout timing warning | 16 nets | DC 对这些网络按 fanout=1000 估算，zero-wire 结果不可信 |
| Max-fanout constraint | threshold 16, actual up to 21 | 不能据此判定物理拥塞，按 16/24/32 比较 QoR |

3.2/2.8 ns 点仍属于旧 RTL，2.5 ns 以后面积从约 3.144M um2 跳到约
2.486M um2，完整 sweep 不能作为单一源码版本的趋势曲线。下一次 sweep 必须记录
commit、dirty-diff hash 和配置，并在源码变化时中止。

### 11.2 Setup path classification

前 20 条 max paths 可归为四类：

1. **P0: persistent O SRAM -> `alpha*O_old` -> PV seed skew.** 前八条以及多条
   后续路径属于这一类。最差路径从 stripe 3 O-bank SRAM Q 出发，经过 32x17
   rescale/mux/add network，到 row-31 `u_pv_seed_skew` stage-0 register。SRAM
   CLK-to-Q 已占 `0.3443 ns`，其余组合路径约 `1.4466 ns`。
2. **P0: normalizer 48x16 scale multiplier.** `scale_mant_q` 到
   `scale_product_q` 仍进入 top 20，已经满足启用固定两级 multiplier wrapper 的
   条件。
3. **P0: 32-lane score scale 32x16 multiplier.** 多个 `scale_requant_unit`
   的 scale input 到 product register 压线，1.7 ns 目标下必须增加可配置乘法流水。
4. **P1: stripe `ws_pv_q` 到 PE `accum_q`.** phase bit 参与共享乘法/累加选择并
   驱动一个 stripe 的 PE。应利用 QK/PV valid-token 互斥消除累加路径上的冗余
   mode mux，或生成 stripe-local registered one-hot enables；不能把一个全局模式
   网直接复制到整个阵列。

当前 PE 17x9 MAC 本身没有进入 top 20，不应先给 1024 个 PE 增加流水级。

### 11.3 Ordered setup optimization

#### P0-A: split SRAM read and O-rescale

在每个 8-row stripe 内、靠近 O-bank 增加一层 `{O_old, alpha, feature, valid}`
operand register，使当前单周期路径拆成：

```text
SRAM Q -> local operand register
local operand register -> 32x17 rescale -> existing row-skew stage 0
```

V column payload、feature tag、seed-zero 和 valid 同步延迟一周期；`pv_done` 必须
等待最后一个延迟后的 feature 写入 O-bank。乘法器仍保持 II=1，因此只增加每个
KV tile 一个 PV startup cycle，不降低 64-feature steady-state throughput。寄存和
乘法应留在 stripe hierarchy 内，避免 O data/alpha 跨越整个 fused-array 后再返回
row skew。

若第二段在 TT 1.7 ns 仍不足，再把 32x17 rescale 替换成 latency=2、II=1 的统一
multiplier wrapper；不要在外围继续堆组合加法或依赖 retiming 穿过 SRAM boundary。

#### P0-B: pipeline both remaining wide multipliers

- normalizer 48x16 使用两级、II=1 wrapper；tag/valid/result-shift 同步增加一级。
- `scale_requant_unit` 32x16 使用可配置两级 wrapper；`EXP_LATENCY` 不再硬编码为
  7，而由 scale latency 与 PWL-exp latency计算，probability column tag/rowsum
  launch 随之对齐。
- ASIC 分支可用固定端口/latency 的 DesignWare pipeline，FPGA 分支保持可推断
  DSP register；两者必须共享 cycle-accurate wrapper contract。

这两项增加 startup latency但保持每周期 32-column exp 和每周期 8-row normalize
吞吐。需新增 back-to-back valid、bubble、极值和 tag-latency regression。

#### P1: remove mode select from the PE score critical path

生成互斥的 `qk_mac_en` 与 `pv_mac_en`：QK 累加只由 Q/K valid token 驱动，PV
乘加只由 V/sum valid token 驱动。`ws_pv` 只控制数据流方向和 phase state，不再
进入 `accum_q` 的乘积选择/写使能关键锥。若物理报告仍显示 control congestion，
每 stripe 再按 8-column group 注册/复制 enable，而不是全阵列广播。

### 11.4 Hold root cause

7424 条 hold violation 全部终止于 SRAM inputs：

| SRAM pin class | Violating paths |
| --- | ---: |
| D | 3840 |
| A | 2624 |
| CEB | 480 |
| WEB | 480 |

最差 D path 只有一个 launch FF CLK-to-Q，arrival=`0.0460 ns`。旧报告把
`0.2000 ns set_min_delay + 0.0200 ns hold uncertainty + 0.1201 ns Liberty hold`
累加成 `0.3401 ns` required time，因此 slack=`-0.2941 ns`。删除人工 min-delay
后，按同一 TT/ideal-clock 数字估算 WNS 约为 `-0.0941 ns`，仍需真实 hold repair。

功能 RTL 中增加一级普通正沿寄存器不能解决该类 hold：新寄存器 Q 到 SRAM D/A
仍是同沿短路径。也不得用 inverter chain RTL 或伪 `set_min_delay` 代替后端修复，
因为综合可能优化掉它们，且无法覆盖 CTS skew、min-RC 和 fast PVT。

### 11.5 Hold repair flow

#### Stage H0: clean logical rerun

1. 清空独立 run directory，显式设置 `SRAM_INPUT_MIN_DELAY=0.0`，并在
   `run_config.rpt` 中检查为零。
2. setup compile 完成后保留 `set_fix_hold [get_clocks core_clk]`，增加可选的：

```tcl
compile -incremental_mapping -only_hold_time
```

该步骤只用于预估 buffer 数和逻辑 setup/hold tradeoff；执行后必须重新报告 max
timing，不能以牺牲 setup margin 为代价清零 hold。
3. 分别报告 SRAM D/A/CEB/WEB 四类 endpoint 的 WNS/TNS/count，不再只给总数。

#### Stage H1: add a real fast/min corner

当前脚本只有 `tt/ss`。增加 0.9-V 设计对应的 fast view：

```text
standard cell: tcbn28hpcplusbwp12t30p140ffg0p99v0c_ccs.db
SRAM:         uhdsp_256x8m4s_ffg0p99v0c.lib/.db
RC:           min-RC
```

逻辑综合 fast view 用于暴露风险，不作为 signoff。正式 MCMM 使用 SS/max-RC 做
setup，FF/min-RC 做 hold，并加载同一 SRAM macro 的匹配 PVT model。

#### Stage H2: CTS/post-route repair

- 完成 CTS 后使用 propagated clock 重算 launch/capture skew。
- 在 SRAM D/A/CEB/WEB branches 上由 P&R 插入合法 delay cells 或 buffer pairs，
  并执行 hold-focused clock/route optimization。
- O-bank/QKV/output SRAM 周围预留 hold-buffer whitespace、halo 和 routing channel；
  不把 launch FF 紧贴 macro pin 到没有插 buffer 的空间。
- 每次 hold repair 后重新检查 SS/max-RC setup，防止 delay insertion 破坏高频路径。
- 最终要求所有 functional/test modes、OCV views 的 setup/hold WNS >= 0；TT
  ideal-clock hold 清零不是签核条件。

### 11.6 Constraint and report cleanup

- sweep summary 从 `timing.rpt` 提取至少四位小数的 WNS，不再使用 `qor.rpt`
  两位小数值。
- 每个 run 保存 source hash、dirty diff hash、library checksum、constraint values、
  top-20 path-category summary 和 high-fanout net report。
- `rst_n` 已被 false-path/ideal-network 处理，`TIM-216` 是无 input-delay 提示，可
  明确 waiver；不能用它掩盖其他 unconstrained endpoints。
- max-fanout threshold 分别跑 16/24/32。当前实际最大约 21，优先以 transition、
  capacitance、buffer count、physical congestion 和 WNS 决定，不追求 threshold=16
  报告清零。
- 继续清理 `VER-318`；`scale_requant_unit` constant zero-point/mode 产生的
  `LINT-28` 应通过专用 score-scale wrapper 或精确 waiver 处理，不要保留 32 份
  无效通用接口。

### 11.7 RTL implementation status for the next synthesis run

P0-A, P0-B, and P1 are now implemented. Each stripe registers O SRAM output,
alpha, feature, zero, and valid before the signed 32x17 rescale; V and its tag
are delayed by the same cycle. Normalizer 48x16 and score-scale 32x16 use the
exact latency-2, II=1 `fa_signed_mult_pipe2` wrapper. Score-scale plus PWL-exp
latency is derived as 5+3=8 cycles rather than hard-coded. PE score accumulation
uses mutually exclusive QK/PV valid tokens and no longer depends on `ws_pv`.

The pre-synthesis RTL gate is 24/24 active regressions, top completion at 1348
cycles, clean width lint, and successful `HEAD_DIM=128` elaboration. These are
functional results only. The next synthesis must establish the new setup area,
register clock power, and fanout numbers; FF/min-RC post-CTS analysis remains
the authority for SRAM hold closure.

### 11.8 Acceptance sequence

1. **Rerun baseline:** current RTL, TT 1.9 ns, min-delay=0，确认新的真实 setup/hold。
2. **RTL timing round:** 实施 P0-A/P0-B/P1 后，23 TB、signed extremes、bubble、
   two-KV recurrence、`HEAD_DIM=128` 和 top cycle model 全部通过。
3. **Logical target:** TT 1.7 ns WNS >= 0.10 ns；SS 2.0 ns WNS >= 0；PE 17x9
   不重复；新增流水保持 II=1。
4. **Logical hold trial:** optional `compile -only_hold_time` 后 hold >= 0，同时 TT
   setup仍满足 margin；只作为 buffer budget 数据。
5. **Physical signoff:** SS/max-RC setup 与 FF/min-RC propagated-clock hold 均通过，
   再以 VCK190 post-route 3.2 ns WNS >= 0 验收 312.5 MHz。
