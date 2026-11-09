# 最终 mapped DDC 的时钟覆盖只读审计

状态：2026-10-18 已完成最终 DDC 只读审计，第二轮 reports_final_v2 的时钟覆盖 PASS。
第一轮 reports_final 保留 UNKNOWN：DC 实际 read_ddc 返回设计名列表，不能当布尔值使用。
已改为直接执行 read_ddc 后核验 top 对象；未修改任何设计、时钟约束或输入 DDC。

PASS 仅指本文件定义的时钟覆盖检查。普通 hold 仍有违例，min-cap 仍有 2 条违例。

## 启动

在33服务器执行；三个参数必须指向本轮**最终**DDC、配套run_config和新的报告目录：

```bash
root=/data/workspaces/zhangcheng/flash_attention
audit=$root/paper_test/clock_audit
synth=$root/asic/dc/work/synth/tt/diffusion_runtime_d/attention_accel_top
bash "$audit/run_audit.sh" \
    "$synth/results/attention_accel_top.ddc" \
    "$synth/reports/run_config.rpt" \
    "$audit/reports_final_v3"
```

若需再次只读审计，必须使用新的目录；上例 v3 尚未运行。
若最终结果实际位于其他目录，替换三个参数。先确认原DC进程结束且综合包装脚本成功。
脚本不根据中间QoR或旧DDC得出本轮结论。

## 边界与库绑定

- 从传入run_config读取原标准单元库/SRAM库，复用工程library_setup.tcl。
- 核对库SHA与run_config的FA_STD_DB_HASH/FA_SRAM_DB_HASH；缺失或失败不判通过。
- 只read_ddc、link及query/report；不create_clock，不重设SDC，不compile/optimize。
- 先保存DDC直接读回的clock_gating_from_ddc.rpt，再调用identify_clock_gating，
  仅刷新内存中的Power Compiler门控分类，另存clock_gating_identified.rpt。
  数量核对使用刷新后的报告，避免瞬态分类属性未序列化造成假失败。
- 保存identify前后全部edge FF及core_clk覆盖计数，并比较core_clk成员精确差集。
  任何计数或成员变化标为UNKNOWN待人工审阅，不能默认为通过。
- 识别不改变网表接线或SDC；审计仍不写DDC、网表或约束。
- 不写网表、DDC、SDF或SDC；所有日志位于新报告目录。
- 审计前后检查输入DDC的SHA一致，防止读到仍在生成的文件。

## 核验

1. 比较全部edge-triggered cells和all_registers -clock core_clk的集合差。
   no_clock_registers.txt列出缺失对象，不能用WNS=0替代覆盖检查。
2. 核对实际mapped ICG=28、SRAM=480；刷新分类后的门控报告应为
   pre-existing=28、tool-inserted=0；直接读回的原始分类报告也完整保留。
3. 对每个SRAM的CLK分别检查：
   - 电气连接可回溯到root clk，仅接受已知ICG CP→Q或单输入非时序buffer/inverter。
   - 选取该macro真实受时序分析的输入路径，检查endpoint_clock=core_clk，
     endpoint_clock_pin必须等于该macro的CLK。
   - 是否出现在all_registers clock-pin集合单独记录；SRAM不在普通FF集合不自动失败，
     仍必须通过实际STA路径的clock ownership证明。无路径/未知属性不会默认通过。
4. 对28个ICG的E端保存max/min完整clock-expanded路径及slack，确认CP属于root时钟。
5. 保存详细check_timing、独立unconstrained_endpoints检查、setup/hold和约束报告。
6. 保存最坏 20 条 hold 路径分类及 2 条 min-cap 的高精度约束、连接、驱动库 pin 信息。
   report_net/report_cell 的 -connections 会忽略 -significant_digits，工具告警原样保留；
   min-cap 约束报告独立以 8 位精度输出，不能把连接报告当作无负载的证明。

DC V-2023.12-SP5手册没有记录check_timing的no_clock检查关键字，不能照搬PT用法。
这里将no-clock作为明确集合差检查，并对SRAM以STA endpoint_clock作独立验证。

## 结论文件

- summary.json：机器可读PASS/FAIL/UNKNOWN与计数/原因；任何未知命令/属性不判PASS。
- sram_clock_ownership.tsv：每个macro的结构可达性和STA clock ownership。
- icg_enable_checks.tsv：每个门控E端的setup/hold路径数、clock及slack。
- no_clock_registers.txt、mapped_icgs.txt、mapped_srams.txt与详细rpt供复核。
- core_clk_members_{lost,gained}_after_identify.txt保留识别前后的覆盖差集。
- power_clock_identified.rpt单独保存识别后的vectorless/default-activity功耗估计。
  不覆盖主综合power.rpt；可用于核对原流程report_power先于identify的分类影响。
  此审计不读SAIF，因此该功耗报告不是基于模型活动的测量或能量数据，不能据此
  宣称动态功耗优化收益；DDC已有活动/工具默认假设仍须结合报告说明。

PASS仅表示该只读审计项目通过；不是CTS/布局布线或芯片时序签核。
ICG E端负slack会使审计FAIL，普通数据路径时序仍需结合timing/constraints报告审阅。

## 本轮结果与边界

- DDC SHA 前后相同：b03b398f2e2cac9274fe9c02b1aa8d8fa10d3cefe6537aae68dfcdeae22129f2。
- 244581 个 edge-triggered cells 全部归属 core_clk，含 480 个 SRAM；普通 FF 数为 244101。
- identify 前后覆盖数量、成员差集均不变；0 个 no-clock cells，0 个 unconstrained endpoints。
- 28 个已有 ICG、480 个 SRAM；自动插入 ICG 为 0。
- 480 个 SRAM 的结构 trace 和 STA clock ownership 全通过。
- 28 个 ICG 的 E 端 setup/hold 全通过，最小 slack 分别为 +0.585210 / +0.0522154 ns。
- 普通数据最坏 hold 为 -0.0971237 ns；综合 QoR 的 6409 条违例仍然存在。
- 2 条 min-cap 均为 ideal reset 网络中的 dont_touch INVD0 输出，实际有 3/6 个负载。
  高精度约束报告算得 total cap=0、required=0.00041000 pF；不能描述为空载 net。
- 识别后默认活动估计 dynamic=5.2662 W、leakage=9.2669 mW，clock_network 占 99.72%。
  原综合 dynamic=4.8309 W；二者都不是 SAIF 结果。此差异说明默认活动/分类的影响，
  不能据此宣称真实功耗增减。根 clock transition 固定 0.05 ns、时钟网络 ideal delay=0；
  未额外查询高扇出 ICG Q 的 cap/transition/ideal 属性，故其物理负载影响仍未定量。

compact_evidence.json / compact_evidence.md 与 evidence_sha256.json 保存紧凑结论和原文件哈希。

## 命令依据

已核对服务器本机安装的Synopsys V-2023.12-SP5手册：
`doc/syn/man/cat2/{read_ddc,all_registers,get_timing_paths,get_pins,get_nets,`
`get_ports,get_cells,index_collection,report_clock,report_clock_gating,`
`check_timing,redirect}.2`。

get_timing_paths手册明确列出endpoint_clock、endpoint_clock_pin、slack属性；
all_registers手册支持-edge_triggered/-clock/-cells/-clock_pins/-include_icg。
命令在实际读回时若不受当前DC支持，记录UNKNOWN并返回非零，不以空集合默认通过。

本目录 evidence/ 为成功 v2 审计报告的逐字节副本；原尝试仍在原目录。
复核优先读 evidence/compact_evidence.md 和 evidence/summary.json。
