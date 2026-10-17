# FLOPA 运行时 d 优化实施报告

更新：2026-10-18。RTL/UVM 短验收和新版本映射综合已完成。
门控时钟的 DDC 只读回查已通过；以下综合数据来自实际发布报告。

## 1. 交付边界

工程：`/data/workspaces/zhangcheng/flash_attention`。
分支：`codex/diffusion-runtime-d`。
功能验收和综合输入提交：`fc9e921069a6f9e6aa41921857143418a9ba13a4`。

本轮实现面向高分辨率扩散 Transformer 的双向稠密 MHA Attention 核。
同一物理实例 MAX_D=128，运行时 d=1–128，重点覆盖原生 d=64/72/128。
保留 32×32 PE、P 驻留、在线 softmax、跨 KV tile 的 O 状态和 QKV 双缓冲。
移除 LLM Decode/causal 模式电路，保留一般尾 token 掩码和完整多头循环。
本轮未修改论文 Architecture 原文或图，也未将旧 PPA 数值当作新版结果。

## 2. RTL 改动

### 2.1 容量固定，实际维度按 job 配置

- HEAD_DIM（0x50）为实际 d；START 校验并快照到当前 job。
- MAX_D（0x90）为只读 128；tile Q/K 固定 32，接口版本为 0x00030000。
- busy 配置写只影响下一 job；busy START、非法 d 和旧模式控制拒绝。
- QK、PV、归一化、loader、输出长度和 head 对齐均使用同一实际 d。
- SCORE_SCALE/OUT_SCALE 同样快照；缩放由软件按实际 d 和量化尺度计算。
- d 计数为 8 bit，feature 地址为 7 bit，d=128 不截断为 0。

### 2.2 Feature-major 装载和紧凑输出

```text
                 token0    token1       ...    token31
feature address0 Q[0,0]    Q[1,0]       ...    Q[31,0]
feature address1 Q[0,1]    Q[1,1]       ...    Q[31,1]
                 ...
feature address71 Q[0,71]  Q[1,71]      ...    Q[31,71]
```

每行 32 个 INT8，即 256 bit；loader 两个 128-bit beat 拼一行。
d=72 时每个 Q/K/V tensor tile 分别传 72 word、144 beat、2304 byte。
地址 72–127 不装载，也不执行对应 QK/PV feature。N 尾 tile 仍按 32-lane
word 传输，无效 token lane 被屏蔽；本接口没有压缩尾 tile 的 token 字节。

输出内部仍预留 128-byte 行槽，外部只写每行实际 d byte。
48-byte reservoir 跨行拼接 AXI beat，末 beat 保留真实 WSTRB。
每头跨度为 align_up(Nq*d,16)，头尾对齐空隙不属于输出张量。
输出拼接有真实控制和取数成本，不能宣称可配置 d 没有周期或面积开销。

### 2.3 O 存储、掩码与门控

- O 每行采用两个完整 128×32-bit 版本，旧版本读、新版本写。
  仅在上一 PV 全部排空后切换版本；归一化读取最后完成的版本。
- QKV 逻辑分配 24 KiB，O 双版本 32 KiB，输出 4 KiB，合计 60 KiB。
  物理存储 120 KiB、480 个 256×8 SRAM 宏，已由最终 DC 报告核实。
- 尾 token 掩码改为 32-bit row-valid 与 32-bit col-valid，替代 1024-bit
  全矩阵掩码寄存器。960 bit 是 RTL 状态减少量，不是实测面积节省。
- 28 个显式工艺 ICG，覆盖必要 reset/clear/valid/drain/SRAM 返回窗口。
  自动门控插入关闭；门控空闲检查与高相位 enable 检查均通过。
- normalizer 精确 32×31 signed 乘法拆分部分积并增加一级流水，II=1；
  metadata 同步延迟，不改数值截位、PWL、舍入或饱和语义。

## 3. 短序列功能验收

采用同一 simv，ASIC SRAM 行为模型，不带 SDF、不生成波形或 SAIF。
软件逐字节 scoreboard 与实际 loader 握手、QK/PV/norm issue 计数、
AXI 写回检查共同验收。

| UVM 测试 | job 数 | 检查输出 byte |
| --- | ---: | ---: |
| 连续 d=64/72/128/72/64 | 5 | 2976 |
| d=1–128 全范围小 N | 128 | 8256 |
| 原生 d × N=31/32/33/65 | 12 | 42504 |
| 原生 12/16/12 头、Nq=3/Nkv=5 | 3 | 10368 |
| 非法配置、busy、复位与恢复 | 3 | 624 |
| 缩放、舍入、饱和数据 | 6 | 1584 |
| 合计 | 157 | 66312 |

六类测试 UVM_ERROR=0、UVM_FATAL=0。覆盖随机 AXI backpressure、输出末 beat、
d=72 跨行拼接/多头对齐、未用 feature 不请求、旧 job 状态不泄漏、空闲门控。
所有有效输出 byte 恰好写一次；head 对齐空隙不写；各头输入/参考独立。

额外模块定向测试：

- 577 个实际完成比较的 signed 32×31 精确乘法样本，含边界、随机、bubble 和 reset。
- 81 组 ×8 lane normalizer，含精确值/tag、II=1、负数舍入/饱和和关闭时钟后 clear；
  此模块测试固定 L=32768，其他在线 row-sum 状态由 UVM 参考模型检查。
- ICG enable 高相位变化不截断脉冲；idle 可停止，test enable 可打开。

这批短测试不是长回归或模型数值质量评估；其总周期含配置/装载/停顿，
不能直接作为论文 Attention 性能数据，也不沿用旧版功能覆盖率百分比。

## 4. 来源绑定与复现

### 格式整理阶段

为满足 4 空格缩进和新增/修改行不超过 100 字符，在独立 Git worktree
`/data/workspaces/zhangcheng/flash_attention_style_review` 整理格式。
分支 `codex/runtime-d-style-review`，当前提交为
`1382d3e0838e60c9f98dfb03a525194d1e6c1357`。
17 份 HDL 文件相对 fc9e921 的 token、字符串和注释正文均相同；
未改变 RTL 运算、状态转换或时序配置。37 份本轮代码/Makefile 差分格式检查通过，
Make recipe 的必要 Tab 为语法例外。证明保存在该提交的 paper_test/provenance/formatting。

格式版另编译一个 simv，完整重跑同一批短验收：六类 157 job、66312 byte，
error/fatal 全为 0；577 个精确乘积、81×8 normalizer 和 ICG 模块检查再次通过。
此后仅补 Tcl 续行格式和 Python 报告 helper；逐项确认 53 个编译输入 SHA 未变，
据此重新绑定最终提交，不重复运行相同 suite。
该批 compile source SHA256 为：
`b121c7d876a948a0a8754c3477f7127db2f2b7487d4f4c56b17076e95304fdeb`。

helper 的路径选择、越界/符号链接拒绝、综合凭证 SHA 选择共 15 项正反例通过；
未使用 PPA 预测数据。综合完成后，这些变更已快进合并至主工程。
格式版构建复制到 `tb/sim/build/runtime_d_formatted`，原功能构建保留。
重新检查来源、二进制和日志后生成当前验证凭证；没有重跑长回归或重新综合。
综合的输入提交仍是 fc9e921，不能改写成之后的格式提交或文档提交。

### 综合原始输入

最终 compile source SHA256：
`fef8c73fc62151bb6b439b9fd03dac17dd4f768ef1db6b3d27d380bf9b7c6761`。

`tb/sim/build/runtime_d/compile_manifest.json` 逐项记录源码、SRAM 模型、
工具路径和 simv hash；编译前后源码一致。
`paper_test/provenance/validation_fc9e921.json` 原样保存实际放行本次综合的凭证，
其 SHA256 为 `23441f93fa63a906aeebea4d23a1cfc3ae63407539b67021a9c690b562e26767`。
`paper_test/provenance/validation_1382d3e.json` 保存格式版验收凭证。
可更新的 `paper_test/validation_manifest.json` 是当前源码的本地生成文件，
报告提取必须按 run_config 内的准确 SHA 选择原始凭证，不能用较新的通过记录替代。
SKIP_COMPILE 仅在来源和二进制均匹配时复用，不允许旧 simv 冒充新 RTL。

```bash
# 原始构建用于复核实际综合输入，格式版用于当前源码校验。
python3 tb/sim/scripts/runtime_d_manifest.py check . tb/sim/build/runtime_d_formatted
RUNTIME_D_OUT_DIR=tb/sim/build/runtime_d_formatted \
    python3 paper_test/build_validation_manifest.py
python3 paper_test/report_synthesis.py
# 重新执行时使用新目录，保留原始构建及其日志。
RUNTIME_D_OUT_DIR="$PWD/tb/sim/build/runtime_d_current" make runtime-d-smoke
# 未来再次综合的入口：make synth-verified；本轮已完成，不重复启动。
```

阶段 Git：

| 提交 | 内容 |
| --- | --- |
| 4e84950 | 冻结优化前基线与作者已有修改 |
| f5a8f0b | 新综合 group 与功能通过门槛 |
| ee22914 | 运行时 d、dense datapath、O/输出/ICG 实现 |
| 021b746 | 尾 token 掩码因子化 |
| fc9e921 | 最终短验证、来源绑定和接口文档 |
| da85492 | 独立 worktree 格式整理及 HDL 等价证明 |
| 79d70ea | Tcl 续行格式与补充证明 |
| 1382d3e | 构建路径和准确 SHA 凭证选择；已快进合入主分支 |

## 5. 新版综合

综合输入为上述功能提交；28 nm TT、0.9 V、25°C，目标周期 1.60 ns。
使用现有标准单元/SRAM 库；16 核 DC；新 group 为 diffusion_runtime_d。
独立 staging，只有结果通过检查才发布，不覆盖旧 system group。

综合正常完成并发布。工具 elapsed time 为 4891 s；未重跑第二次综合。
最终结果放在：
`asic/dc/work/synth/tt/diffusion_runtime_d/attention_accel_top/reports/`。
提取入口为 `python3 paper_test/report_synthesis.py`。

| 指标 | 新 MAX_D=128 实例 | 旧 system 基线 |
| --- | ---: | ---: |
| 工艺/条件 | 28 nm TT / 0.9 V / 25°C | 相同 |
| 目标周期 | 1.60 ns（625 MHz） | 相同 |
| Total cell area | 2.452363943 mm² | 2.436075167 mm² |
| SRAM cell area | 0.656746699 mm² | 0.656746699 mm² |
| SRAM 宏数 | 480 | 480 |
| 显式 ICG / 自动插入 ICG | 28 / 0 | 0 / 0 |
| Setup WNS / 违例数 | +0.0000 ns / 0 | +0.0000 ns / 0 |
| Hold WNS / 违例数 | −0.0971 ns / 6409 | −0.0953 ns / 5939 |
| Hold TNS | −420.20 ns | −403.42 ns |

总 cell area 增加 16,288.776 µm²，约 0.669%；同一宏库下 SRAM 面积不变。
新版同时改变了最大 d、O 存储布局、门控、模式和流水，不能把总面积差单独
归因为运行时 d 或 P 驻留。d=64/72/128 共用这一个面积结果，不能按 d 缩放。

最终检查确认无 generic/unmapped cell，1236 个乘法 wrapper 与 1236 个
DW02_mult 绑定一致；28 个显式 ICG，自动插入为 0。工具时钟门控报告为
242,589 / 244,101 个门控寄存器（99.38%）；这只是结构覆盖，不是功耗节省率。
源码、标准单元库和 SRAM 库 SHA 与综合输入一致。

最差 setup 路径已由旧 normalizer reciprocal 转至 score-scale 的流水部分积；
arrival 1.4895 ns、required 1.4896 ns。当前只满足相同 1.60 ns 目标，
没有重新扫描最高频率，不能据此声称 Fmax 提高。

最差 hold 路径为 output pack 寄存器到输出 SRAM D 口；6,409 个 hold 违例
端点均为 SRAM A/D：O banks 3840、QKV cache 2208、output buffer 361。
`timing_status.rpt` 的 hold_violating_paths=1 是“存在违例”的布尔值，
实际条数见 QoR。当前 physical_aware=0、logical_hold_repair=0，
没有完成 CTS/布线或 hold 修复，不能称为时序签核通过或可流片实现。

max-transition 和 max-capacitance 违例为 0，但有两条 min-capacitance 残留：
`u_fused_array/n25936`、`u_fused_array/n113247`，均受 dont_touch 约束。
只读 DDC 高精度回查确认每条最小电容要求为 0.00041000 pF，
工具计算 total capacitance=0，违例 −0.00041000 pF，不能笼统写“所有 DRC 为 0”。
两网由 rst_n 分支的 dont_touch INVD0 驱动，分别有 3/6 个负载，
不能称为空载。单个 load pin 有非零 cap，SDC 将 rst_n 声明为理想网络；
此处物理负载仍待实现后核实。
`check_timing` 未列出 unconstrained endpoints；异步 rst_n 未设置普通输入延迟，
另有 26 条高扇出网络提示，均保留原报告供后续物理实现检查。

### 5.1 功耗边界与门控时钟回查

原始 `power.rpt` 报告总功耗 4840.6 mW，其中动态 4.8309 W；这是
`identify_clock_gating` 之前产生的默认活动 vectorless 结果。
该数字不能当成模型活动功耗，也不能与旧 gate-SAIF 的 658.4835 mW 比较。
已以原始 DDC、相同库/约束完成只读回查；未改 RTL、未 optimize 或重新综合，
原 DDC 和 power.rpt 未覆写。审计脚本、summary、逐宏和逐 ICG 证据放在
`paper_test/clock_audit/`。审计 PASS 只代表以下时钟覆盖检查通过：

- 全部 244,581 个 edge-triggered sequential cells（244,101 寄存器和 480 SRAM）
  均属于唯一 core_clk；无未覆盖对象。每个 SRAM 同时核对结构源和 STA clock owner。
- identify 前后成员集合完全一致，无丢失/新增；28 个显式 ICG、0 个自动 ICG。
- 28 组 ICG E 均有 setup/hold 路径，最小 slack 分别为 +0.585210 ns / +0.0522154 ns；
  没有通过添加假时钟或放宽约束消除空路径。
- DDC 回查前后 SHA256 相同：
  `b03b398f2e2cac9274fe9c02b1aa8d8fa10d3cefe6537aae68dfcdeae22129f2`。

识别后的独立 `power_clock_identified.rpt` 总功耗为 5275.7 mW，
动态 5.2662 W，clock_network 分类占 99.72%；它依然使用默认活动，未读 SAIF，
并有未标注 black-box 输出警告。分类顺序改变了该默认估计，不能从任一结果
推导模型能量或门控节省率。这组数值明显高于历史活动结果，需要后续以同输入活动、
时钟网络条件和物理实现核验；本轮既不把它当作节能结果，也不隐去该风险。
时钟覆盖 PASS 不代表上文 6409 个 SRAM hold 违例或 min-capacitance 已修复。

本轮没有新模型 SAIF、门级带 SDF 仿真、工作负载功耗、能效或模型吞吐数据。
不将旧周期/旧功耗按新频率比例改成新结果；后续模型实验单独采集。

分析/展开警告已逐类复核：row/column 的 integer 转换范围为 0–31；
output 行号范围为 0–7；两位 output FSM 的四个 case 已覆盖全部硬件编码；
精确乘法的 high/low 切片和 63-bit 符号扩展保留正确位模式。
PE 的低 32-bit 结果截取沿用 INT32 累加语义，不能由此宣称任意极端长序列均不溢出。
这些警告未发现需要中断综合的功能问题，结论受上述短测试范围限定。

## 6. 运行时 d 的论文取舍

建议主实现使用同一 MAX_D=128 实例和 regfile 实际 d，原生覆盖 64/72/128。
P 驻留与 O 持久化是主要数据流贡献；运行时 d 用于支持真实模型和解释硬件通用性。

运行时 d 需要 job 配置/快照、动态终止判断、尾 feature 和紧凑输出控制。
原 HEAD_DIM 寄存器已存在，本轮复用其地址和快照，不把它描述为整套新寄存器。
MAC 精度和 PE 数量不因 d 可配置而增加；物理存储按 MAX_D 保留。
当前 SRAM 宏存在深度余量，QKV 的 d64→128 不必增加宏数，不能用逻辑容量
翻倍推断物理面积翻倍，也不能因此宣称运行时控制完全免费。
动态终止比较仍可能进入时序路径；实际面积/频率代价需对齐其他改动后测量。

如果后续需要固定 d 对照，应保持同一 O 组织、门控和数据流，只改变维度选择，
并统一最大容量或明确容量差异。不能把本轮综合相对旧 d64 基线的全部差异
归因于 regfile 配置，也不需要为主结果换三份网表择优报告。
