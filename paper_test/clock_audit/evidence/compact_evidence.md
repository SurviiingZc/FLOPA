# 最终 DDC 时钟覆盖只读审计

结论：时钟覆盖 PASS；普通 hold 和 2 条 min-cap 仍有违例，不能称完整时序签核。
审计未 compile/optimize、未修改设计/SDC、未写网表/DDC。

| 项目 | 结果 |
| --- | --- |
| 全部 edge-triggered cells / core_clk 覆盖 | 244581 / 244581 |
| 普通 FF / SRAM | 244101 / 480 |
| no-clock / unconstrained endpoints | 0 / 0 |
| identify 前后 core_clk 成员变化 | gained 0 / lost 0 |
| 已有 ICG / 自动插入 ICG | 28 / 0 |
| SRAM 结构追踪及 STA clock ownership | 480 / 480 PASS |
| ICG E setup 最小 slack | +0.585210 ns |
| ICG E hold 最小 slack | +0.0522154 ns |
| 普通 hold 最坏 slack / 综合 QoR 违例数 | -0.0971237 ns / 6409 |
| 本次保存的最坏 hold 路径 | 20 条，均 output buffer → SRAM D |
| min-cap | 2 条；required 0.00041000 pF，工具 reported actual 0 |

DDC SHA 前后相同：
`b03b398f2e2cac9274fe9c02b1aa8d8fa10d3cefe6537aae68dfcdeae22129f2`。

## 两条 min-cap 的实际连接

`u_fused_array/n25936` 由 `U25823/ZN` 驱动，3 个 load pins；
`u_fused_array/n113247` 由 `U119892/ZN` 驱动，6 个 load pins。
两者驱动均为 dont_touch `INVD0BWP12T30P140`，输入来自 rst_n。
SDC 明确 `set_ideal_network [get_ports rst_n]`，连接报告各负载 pin cap 非零，
而该理想网络总 cap 被报告为 0。因此不能把它们写成没有负载的悬空网。
高精度约束在 `min_cap_constraints_highprec.rpt`；driver/net/lib-pin 明细均保留。
连接报告的 significant_digits 被工具忽略，UID-451 告警原样保留。

## 默认活动功耗的边界

原综合 report_power：dynamic 4.8309 W。
identify 后独立 report_power：dynamic 5.2662 W，leakage 9.2669 mW，
clock_network 占 99.72%。两者均无 SAIF 读入，不能当模型功耗、能量或节能证据。
识别后报告仍有未标注 primary inputs、sequential outputs、black-box outputs 告警。
该差异显示默认活动/门控分类顺序对估计有影响，不能直接归因为真实功耗退化。

现有 reports 显示 core_clk 周期 1.6 ns，所有 rise/fall max/min transition 0.05 ns，
时序路径采用 ideal clock-network delay=0，26 条 high-fanout nets 采用计算 fanout=1000。
没有额外查询最高负载 ICG Q 的 cap/transition/ideal 属性，故其物理负载影响尚未定量。
审计会话已退出；按要求不为该问题再次开启 DC。

## 保留的尝试

第一轮 `reports_final` 为 UNKNOWN：当前 DC 的 read_ddc 返回设计列表，旧审计把它当布尔。
修复后直接执行 read_ddc 并核验 top；第二轮 `reports_final_v2` exit 0。
前一轮记录不覆盖。脚本、summary JSON、时序/功耗/连接报告及 SHA 清单全部保留。
