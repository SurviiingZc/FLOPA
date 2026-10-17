# 面向高分辨率扩散 Transformer 的 FLOPA RTL 优化计划

更新：2026-10-17。状态：待作者审核；本文是实施计划，
尚未裁剪主 RTL、生成新网表或测得优化后的 PPA。

本次决定：采用同一物理实例的运行时 d，编译期 MAX_D=128；
撤销旧版“分别编译固定 d=64/72”的方案。审核完成前不实施 RTL 修改或测试。

## 1. Workload 与硬件边界

模型覆盖 PixArt-Sigma、DFoT-MCRAFT 与 Wan2.1-T2V-1.3B。
三者同口径 GPU profiling 已完成；原生 ASIC 回放与优化后 PPA 均待实施。
本轮硬件目标是 batch-1、双向、稠密、多头 self-attention 的 QK/softmax/PV 核。
模型 QKV projection、RoPE、文本编码、VAE 和完整 denoising loop 在核外完成。
导出的 Q/K/V 必须位于模型规定的 QK normalization/RoPE 之后。

| 模型 | 完整 Attention 形式 | 头数 | 原生 d | 主要 N 变化来源 |
| --- | --- | ---: | ---: | --- |
| PixArt-Sigma | 空间 full self-attention | 16 | 72 | 图像分辨率；2K 方图为 16384 patch tokens |
| DFoT-MCRAFT DiT/B | 时空 full self-attention | 12 | 64 | 固定 256×256 空间尺寸，改变帧数；50 帧为 12800 |
| Wan2.1-T2V-1.3B | 全局时空 self-attention | 12 | 128 | 已测固定 13 帧、分辨率扫描，N=1024–16384 |

模型中的多帧依赖、history conditioning 和 3D RoPE 不等于 causal Attention。
现有 MCRAFT functional signature 已确认 attn_mask=null、is_causal=false。
首版使用同一 MAX_D=128 物理实例，运行时支持 d=64/72/128，PE 阵列仍为 32×32。
接口目标是 1≤d≤128，原生模型三种 d 为重点验收值；只有通过全范围短序列
回归与边界测试后，才对外宣称任意 d 可用。未验证范围须明确限定。
每个 job 只执行实际 d，不将 72 维裁为 64，也不补零后执行满 128 维。
论文主表报告这一个 MAX_D=128 实例的物理面积，不能按运行时 d 缩放面积。

## 2. 已核实的基线事实

主工程：`/data/workspaces/zhangcheng/flash_attention`。
审计的综合目录：`asic/dc/work/synth/tt/system/attention_accel_top`。

- run_config：28 nm TT，0.9 V/25°C，周期目标 1.60 ns；physical_aware=0。
- RTL hash：`d31a35dc02783c6ed1a02068ff107af362343ab13ce487aa3ce4ec82193dc791`。
- 总 cell area 2.436075 mm²，SRAM 0.656747 mm²，480 个 256×8 宏。
- `clock_gating=none`、`rtl_icg_count=0`、`automatic_clock_gating=0`；
  clock_gating.rpt 给出 241929 个未门控寄存器、0 个门控寄存器。
- timing_status：setup violating paths=0，hold violating paths=1，hold_enforced=0。
- max-delay 首路径从 normalizer 的 acc_s2 到 reciprocal multiplier 的部分积寄存器。
- min-delay 首路径从 PE sum_data 寄存器到 O-bank SRAM 输入。

这些是已有映射报告的事实，不等于布局后面积、实测最高频率或签核时序结果。

## 3. 裁剪与保留清单

| 功能 | 决策 | RTL 定位 | 具体动作与验收 |
| --- | --- | --- | --- |
| 单 token Decode 模式 | 删除 | control/accel_regfile.v:98、accel_scheduler.v:65 | 删除模式快照、Q tile 特判、Decode 状态位；非因果 dense 输出与旧版逐位相等 |
| Decode 的 query 位置重映射 | 删除 | attention_accel_top.v:358 | 删除用 seq_kv-1 替代 q_base 的 mux，直接使用真实 Q tile base |
| Decode 单行输出旁路 | 删除 | attention_accel_top.v:558 | 删除强制 valid_q_rows=1；保留一般尾 tile 有效行计算 |
| causal 三角掩码 | 首版删除 | compute/fsa_fused_array.v:431 | 去掉逐行因果比较，保留 Q/K 有效 token 与尾 tile 掩码 |
| GQA 模式和重复 head 配置 | 简化 | accel_regfile.v:110、accel_scheduler.v:68 | 当前 GQA 本来就被拒绝，不能宣称删掉了一套 GQA datapath；合并 MHA 头数配置 |
| Prefill/Decode 双模式选择 | 简化为 dense job | 寄存器与 scheduler 接口 | 保留 start/busy/done/error，不再把完整扩散 Attention 命名为 LLM prefill |
| d 配置寄存器 | 改成真正运行时配置 | accel_regfile.v、QK/PV/top/output | MAX_D=128 固定容量；job 锁存实际 d；全链路按 d 终止，拒绝非法值 |
| tile 配置寄存器 | 固定为 elaboration 合约 | accel_regfile.v | tile=32 作为只读能力值；不与运行时 d 混为同一种配置 |
| 多头循环 | 保留 | accel_scheduler.v | 12/16 个头仍需全部计算；不能只测单头后漏算整体成本 |
| 尾 token/尾 feature | 保留并加强 | fused_array、output_buffer | N 非 32 倍数及 d=72 都需要，不能随 causal 一起删除 |
| P 驻留、在线 m/l 更新与 O 持久化 | 保留 | fused_pe、stripe、o_accumulator_bank | 属于论文主旨，跨 KV tile 的输出重缩放不能裁掉 |
| Q/K/V ping-pong 与 AXI backpressure | 保留 | qkv_tile_cache、pingpong_buffer、axi | 长序列依赖加载/计算重叠，不用减少 bank 数换取未报告的 stall |
| 关键计数器、错误检测与软复位 | 保留 | perf_counter、regfile | 延迟与访存仍须可测；调试探针尽量放 testbench，不混入论文 PPA |

词法上的 segment decode、地址 decode、FSM 输出 decode 均为必要电路，
不属于本计划所说的 LLM Decode，不能按关键字批量删除。

非因果掩码可研究由 32 个 row-valid 与 32 个 col-valid 因子构造，
替代一般三角掩码的计算；仍需检查扇出、时序和空行在线状态，不能假定综合一定更小。
每个 denoising step 的 Q/K/V 都会变化，不引入跨 step 的静态 KV-cache 复用假设。

## 4. 重点一：MAX_D=128 容量与运行时 d

### 4.1 容量、配置与 job 快照

- 编译期 `MAX_D=128` 决定 SRAM、计数器和 tag 的最大宽度，运行时不改变容量。
- 沿用 regfile 的 HEAD_DIM 寄存器地址作为实际 d；新增或明确只读 MAX_D 能力值。
  现有 HEAD_DIM 已经是 8 bit，不是重新增加第二个重复 d 寄存器。
- START 时校验并锁存 `d_active`，QK/PV/normalizer/loader/output 使用同一快照。
  busy 期间配置写只影响下一个 job，不改变当前 job；busy 时重复 START 拒绝。
- d 的接口合法范围为 1–128；0、129–255 拒绝，报配置错误且不发起计算或访存。
- feature 地址/tag 是 7 bit，表示 0–127；循环次数/长度至少 8 bit，必须能表示 128。
  禁止把 d=128 截断成 7 bit 的 0，或把末维判断错误地延迟到第 129 次操作。
- job 切换必须 drain 完成；d 变化时失效旧 cache 所有权、pending 半 beat、
  输出打包与 tag 状态。用 valid/代际管理隔离旧数据，不要求清零整个 SRAM。
  新 query/head 的首个 KV tile 仍以零 O seed 开始，并初始化在线 m/l 状态。

### 4.2 当前代码审计与修改清单

| 路径 | 当前事实 | 计划修改 |
| --- | --- | --- |
| regfile | 已有 prog/cfg_head_dim，但 START 强制等于 HEAD_DIM 参数 | 校验范围并保留 job 快照，容量参数更名/区分为 MAX_D |
| QK engine | 已用 head_dim_i 控制 issue/receive，仍受 HEAD_DIM_LIMIT 限制 | 按 MAX_D 配宽度，确认仅发 d 个 feature 并在 d−1 收尾 |
| PV engine | FEATURE_LIMIT/LAST 均为编译常量，没有运行时 d 输入 | 增加 active d；只请求 d 个 V feature，tag/drain 对齐 |
| fused array | 完成条件使用编译期 FEATURE_LAST | 以 active d−1 判断最后 feature；P 与 score 的 tile 大小不变 |
| O bank | 容量和物理 group 由 HEAD_DIM 决定 | 按 MAX_D 设容量；地址/tag 使用实际 feature，闲置 group 不访问 |
| 最终归一化 | top 中 norm_feature 对比编译期 FEATURE_LAST | 只遍历实际 d，正确处理最后一个不满 32-feature 的 group |
| output buffer | GROUPS、末组填充和流地址均依赖编译期 HEAD_DIM | 最大物理布局固定；实际有效长度、末组与输出字节流按 active d |
| top/loader/计数器 | OUTPUT_ROW_BYTES 编译常量，外部 loader 提供 tile | 同步实际 d 的装载长度、字节数、head 步长和 MAC 统计 |

现有 QK 的局部支持不能作为整个芯片已支持运行时 d 的证据。
所有请求、返回和写回 tag 必须同一 job；不按当前配置重新解释在途数据。
START 阶段预计算 d−1、末组有效数、输出长度和 stride，避免把这些计算放到
逐 feature 关键路径；32-feature group 继续用位切分寻址，不引入通用除法。
softmax 的概率列 tag 仍对应 32 个 PE 列，不因 MAX_D 改成 128 列。

### 4.3 SRAM 与外部数据布局

- Q/K/V cache 仍按 feature-major 存储：每个 feature 地址装 32 个 INT8 lane。
  每个 tensor/tile 只装载 d 个 256-bit word，即 2d 个 128-bit loader beat。
  N 尾 tile 的无效 token lane 单独屏蔽，不补充 d 到 128 的传输。
- 若暂沿用当前 O 分组，MAX_D=128 对应四个 32-feature 物理 group。
  d=64 仅访问前两个，d=72 访问前两个加第三个的 8 个位置，d=128 访问全部。
  不把“实际访问 3 组”误称为物理上只有 3 组，不能越界读写未初始化维度。
- 输出物理槽可先固定为每行 128 字节，但外部逻辑输出必须只含实际 d 字节。
  d=72 时跳过物理填充，用小型字节拼接缓冲跨行组成 AXI beat；
  禁止把内部 128 字节槽直接连续导出为每行 72 字节的张量。
- tile 内行紧凑排列，写回实际 `valid_rows*d` 字节；末 beat 用正确 WSTRB。
  多头起始地址必须满足 AXI 对齐：优先每个 head 以
  `align_up(N*d, 16)` 为存储跨度，仅 head 末尾允许对齐空隙。
  现有 top 的 `seq_q*o_stride` 和 `32*o_stride` 关系需明确重定义/适配，
  不能只改输出字节数而留下错误 head 地址。若保留可配 stride，要写清协议。
- d=72、奇数 N、多头特别检查 head 对齐；外部框架解包时排除 head 尾部空隙。
  打包、搬运和解包开销计入相应端到端边界，算子核心时间另列。

### 4.4 缩放与数值

score scale 必须对应实际 d，包含模型的 1/sqrt(d) 和 Q/K 量化尺度。
优先由软件计算并与 d 一起写入、锁存已有 SCORE_SCALE 的 mantissa/shift，
复用现有缩放乘法器，不在 RTL 新增运行时开方或除法单元。
输出尺度同样作为 job 配置保持稳定。PWL、round/saturate 和参考模型同步验证；
d=128 检查 QK 累加范围，PV 跨 tile 的重缩放和误差也需回归。
修改前冻结原生模型误差门槛，不将裁剪 d 或饱和结果当成通过。

### 4.5 验收计划（审核后实施）

1. 同一仿真实例连续跑 d=64→72→128→72→64，不重新 elaboration，不换网表。
   用不同数据及未用地址的脏数据，检查无旧 cache/O/输出字节泄漏。
2. 三种原生 d 覆盖 N=1/31/32/33/65、小 N 多头、跨 KV tile、AXI 随机停顿。
   72 维重点检查跨行拼接、最后 beat、奇数 N 时的多头对齐。
3. 小 N 遍历全部合法 d=1–128；重点检查 d=31/32/33、63/64/65、
   71/72/73、96、127/128，以及 d=0、129、255 的错误行为。
4. 覆盖 busy 写配置、busy START、soft reset、最后一维返回与流水 drain。
   各模块发出/接收/写回计数严格等于 d，无第 d 个越界 feature 地址。
5. 统计实际 loader 字节、QK/PV feature 次数、归一化元素和输出有效字节。
   d=64/72 不得执行满 128；总周期保留固定填充/排空/softmax 成本，
   不预设总耗时正比 d。有效 MAC 数与物理尾 tile 空转分开记录。

既有 d=64 PPA 仍是旧基线；新 MAX_D=128 实例统一重新综合并回读活动。
三种 d 共享同一物理面积/网表，延迟与动态能量分别测量，不按 d 比例缩放面积或功耗。

## 5. 重点二：SRAM 组织与容量利用率

当前唯一已确认的可用宏类型为 uhdsp_256x8m4s；不能把 RTL 的 DEPTH 改小就
声称物理宏变小。以下容量按 RTL 结构计算，不是新面积测量。

| 存储 | d=64 有效数据容量 | 当前宏数 | 物理 bit 容量 | 容量利用率 |
| --- | ---: | ---: | ---: | ---: |
| Q/K/V 双缓冲 | 12 KiB | 192 | 48 KiB | 25% |
| O banks | 8 KiB | 256 | 64 KiB | 12.5% |
| 归一化输出缓冲 | 2 KiB | 32 | 8 KiB | 25% |
| 合计 | 22 KiB | 480 | 120 KiB | 18.3% |

P 的 PE 寄存器、score 寄存器和流水寄存器不在上表 SRAM 容量中。
运行时 d 版本先按 MAX_D=128 规划最大容量。以下仅为容量/宏数量推导，
不是优化后综合结果：

| 存储 | MAX_D=128 的逻辑有效容量 | 沿用现组织的物理宏数 | 物理容量 |
| --- | ---: | ---: | ---: |
| Q/K/V 双缓冲 | 24 KiB | 192 | 48 KiB |
| O banks | 16 KiB | 512 | 128 KiB |
| 输出缓冲 | 4 KiB | 32 | 8 KiB |
| 合计 | 44 KiB | 736 | 184 KiB |

Q/K/V 的 64→128 feature 深度仍可用同一 256 深度宏，不必增加宏数；
O group 若直接从 2 扩到 4，则 O 宏数翻倍。输出字宽保持 256 bit、
最大深度 32×4=128，也仍在已有宏深度内。这说明不能机械地扩大所有 bank；
必须结合端口冲突分析优化 O 布局，才能判断最大 d 支持的真实面积代价。
MAX_D=128 实例运行 d=64 时，闲置 SRAM 不会物理消失，也不自动消除漏电。

候选按以下顺序评估：

1. 导出 O bank 各行逐周期 read/write feature，建立同时访问冲突表，
   再决定能否减少物理 bank、改变 feature 到 bank 的映射并利用未用地址。
   原有两个 group 支持读旧 O 与写新 O，不能直接合并成一个单口宏。
2. 评估紧凑 register-file/标准单元存储替代很浅的 O bank 与输出缓冲。
   必须同时比较 mux 面积、读延迟和时钟功耗，不能把移到寄存器当作免费节省。
3. 保留 Q/K/V 双缓冲所需并行读写；按带宽与端口冲突分析后，才考虑共享
   不同时存活的数据区。更少宏数若增加搬运/停顿，需报告实际周期代价。
4. 若将来能取得更浅/更宽的已表征 SRAM 宏，再比较宏选择；当前不假定存在。

验收包括物理 macro count/area、逻辑有效容量、端口字节数、冲突数、
load/compute/writeback 周期以及同输入能量。宏容量利用率不是面积节省率。

## 6. 重点三：有效时钟门控和无效数据翻转

`rtl/common/fa_clock_gate.v:4` 当前明确直接透传根时钟，因此现有 enable
信号并不代表硬件已门控。这是优先于继续加 mode 参数的功耗优化候选。

- 分区：PE、Q/K/V skew、O bank、PV seed、normalizer、output buffer。
- 使用工艺 ICG 或受约束的标准综合门控流程，禁止组合逻辑直接 AND 时钟。
- enable 必须覆盖 valid、流水 drain、reset/clear、SRAM 同步读返回和 AXI stall。
- 测试空闲、长时间 backpressure、tile 切换、最后一列/feature、异步 reset 与
  soft reset；输出与参考保持一致，不能因门控丢失晚到的 tag 或行和。
- 控制逻辑保持必要活动；不对 AXI ready/valid 或错误处理盲目门控。
- 对无效乘法输入、空闲 SFU 操作数做 isolation，区分它和真实 clock gating。

已有 88.5% clock-network 功耗归类来自布局前估计，不等于真实 CTS 时钟树。
验收同时看总动态/漏电、各层级与 ICG 报告；需要模型 Q/K/V 活动重新回读，
不按旧 SAIF 的时钟分类百分比预先承诺节省量。

## 7. 重点四：收敛真实关键路径

先审查 normalizer reciprocal multiplier 的部分积路径及扇出，检查拆分、
流水边界和 metadata/tag 对齐；已有两级乘法器已经存在，不能重复描述成新改进。
新增一级流水若可保持 II=1，应报告每 tile 的 drain 成本及算子总周期。
不能用未经数值验证的位宽截断、PWL 改动或 false-path 隐藏来达标。

同时处理 PE→O SRAM 最短路径的 hold 约束。改变宏映射、门控或流水后，
必须复查 setup/hold、transition/fanout 和 SRAM 读写时序。
优先最小化 C/f 与每次 Attention 的能量，不把频率单独作为优化结果。

## 8. 分阶段版本与放行条件

| 版本 | 修改 | 首要验证 | PPA/论文用途 |
| --- | --- | --- | --- |
| B0 | 冻结旧 d=64 主线 | 保存源码/网表/库/约束 hash 与已有结果 | 历史基线；与新版分开 |
| B1 | 删除 Decode/causal，简化 MHA 寄存器 | 与 B0 非因果子集逐位一致；尾 tile/AXI 回归 | 量化 workload 专用化的实际收益 |
| B2-DYN | MAX_D=128、运行时 d、紧凑输出 | 同实例 64/72/128 切换、全范围短序列、72 字节拼接/多头对齐 | 一个实例覆盖三个原生 head dimension |
| B3 | 存储布局候选 | 单口冲突为零、端口流量与周期不隐瞒 | 面积/搬运机制证据 |
| B4 | 有效 ICG 与 operand isolation | 门控状态转换、drain/reset 回归 | 同输入动态能量对比 |
| B5 | normalizer/控制关键路径调整 | setup/hold 与数值/协议全回归 | 最终频率、面积、总延迟、能效 |

每个候选先通过有针对性的 RTL 回归，才进入综合。最终保留收益清楚的少量版本；
不同时开大矩阵或为所有 N 做慢门级仿真。模型长序列用 RTL 测周期，
门级 SAIF 先选代表输入和可完成的长度，再按证据决定是否扩大。

当前任务只制定上述计划。新硬件 PPA 必须重新综合/检查时序并采集活动；
旧数据不通过频率比例变成新硬件测量。只有同一网表、同一周期数下的
时间换算可明确标注为 C/f；面积、漏电、动态功耗与新版本周期均需各自测量。

## 9. 实验如何回扣论文创新

- 主性能图：真实模型完整 self-attention 的 CPU/GPU/FLOPA 延迟随 N 变化；
  ASIC 为仿真周期和报告时钟，数值误差需通过。主比较应覆盖模型全部头，
  或明确单头边界并另检查 GPU 多头并行，避免以 GPU 低占用人为放大优势。
- 跨栏主表：最终 FLOPA 的逻辑/宏面积、SRAM 容量、时钟、功耗、吞吐与能量，
  并列文献原始口径。H-FA 未单列 SRAM 面积，FSA area 不含 SRAM/DMA，
  缺失项填 NR/未计入，不能填 0 后进行排名。
- P 驻留：统计真实 PE P 写入、P 是否越过阵列边界、O 端口 R/W 与加载流量。
  共享 P 缓冲写读的逻辑下界与实测端口计数分开。若做 P-buffer 对照，
  须明确 state 放置和数据流；只在原设计上额外加无必要 scratchpad 的变体，
  只能表示 spill/reload 代价，不能冒充优化过的竞争架构面积。
- O 持久化：测 O bank 面积与活动功耗、跨 KV tile 读写和预加载开销。
- overlap：保留已有串行调度对照，后续新版重测；不再重复架构时序图。
- B0→B1 的裁剪收益与 P 驻留机制分别归因，避免把所有 PPA 改善都算成 P 驻留。
- 运行时 d：三个模型使用同一 MAX_D=128 实例；单列实际 d 的周期、流量与能量，
  面积统一计入最大容量，不将未访问维度描述为 SRAM 面积节省。

Architecture 的现有文字和图本轮保持原样；实现发生变化并通过验证后，
仅同步真正变更的参数与模块描述，不提前宣称优化已经完成。
