# Attention 硬件加速器设计竞赛完整方案

## 0. 已确认约束与基线结论

### 0.1 已确认约束

1. 目标 FPGA 平台：AMD/Xilinx VCK190，器件为 Versal AI Core VC1902。
2. 综合流程：前期使用 Xilinx/Vivado/Vitis 支持上板，后期稳定后迁移到 DC。
3. 控制接口：AXI4-Lite slave，32-bit 数据宽度。
4. 数据接口：AXI4/AXI4-Stream 数据宽度为 128-bit。
5. 数据格式：以真实 Re10K INT8 量化模型为准，允许自定义定点格式。
6. 真实网络：Re10K transformer，权重和量化参数位于：
   `/home/project/public_fpga/FPGA25_ARIES_AE/dfot_fpga/dfot_test/aie_bins`
7. 功能目标：第一版实现 MHA，后续扩展到 GQA 作为创新点。

### 0.2 合理性分析

VCK190 的资源规模足以支撑比最低要求更强的基线。官方页面给出的 VC1902
资源包括 400 个 AI Engine、1968 个 DSP58、899840 个 LUT、144 Mb BRAM、
288 Mb URAM、DDR4 和 LPDDR4。竞赛要求只强调 RTL、SV 验证环境和 AXI4
接口，因此第一版不依赖 AIE，优先在 PL 中完成完整 Attention 数据通路。

Re10K 量化模型与本题非常契合。已导出的 attention 文件包含 INT8 权重、
scale/zp、以及 attention 相关的 Q、prob、KT、V dump。当前基线按
`num_heads=9`、`head_dim=64`、`seq_len` 可配置来设计，对齐 `hidden=576`
的一类 Re10K attention block。其他 hidden 维度不作为第一版基线约束。

因此第一版固定 `head_dim=64`、`num_heads=9` 是合理的：既贴合真实网络中
较易闭环的一类 attention，又简化 softmax、缓存和阵列调度。MHA 作为第一版
目标合理；GQA 作为扩展也合理，因为 GQA 本质是让多个 Q heads 共享较少的
K/V heads，可复用 MHA 的 cache 和调度。

### 0.3 推荐基线标准

第一版基线定义为“PL RTL 实现的 MHA Attention 加速器”。数据格式采用
INT8 GEMM + BF16/FP-like softmax 的混合精度路线：

- Q/K/V 按 Re10K INT8 输入，QK 使用 INT32 累加，score 转为
  BF16/FP-like 格式进入 softmax、LSE、在线归一化。
- 不做全链路 BF16。这样能保留 softmax 数值稳定性，同时控制 MAC 阵列资源。

| 项目 | 基线标准 |
| --- | --- |
| 平台 | VCK190 / VC1902 |
| 主频目标 | 200 MHz 作为首版目标，150 MHz 作为保底上板目标 |
| 控制接口 | 32-bit AXI4-Lite slave |
| 数据接口 | 128-bit AXI4/AXI4-Stream |
| 输出接口 | AXI4 master burst write |
| 输入接口 | AXI4 slave 数据窗口，后续可接 AXIS/DMA |
| 数据格式 | INT8 GEMM，BF16/FP-like softmax/LSE |
| Attention 类型 | 第一版 MHA，预留 GQA 参数 |
| head_dim | 第一版固定 64 |
| heads | 第一版固定 9，寄存器保留可配置字段 |
| seq_len | 16-bit 可配置，架构上限 65535 |
| 阵列 | 32x32 INT8 MAC 阵列，大于 16x16 |
| softmax | 32 lane 并行 exp 近似，大于 16 |
| KV cache | 流式 K/V tile cache，至少 128 KB |
| 数据流 | FlashAttention-like 分块在线 softmax |
| 验证 | SV testbench + Python bit-accurate reference |
| 真实网络 | 跑 Re10K attention 子层，给误差和延迟 |

### 0.4 分阶段目标

| 阶段 | 必须完成 | 说明 |
| --- | --- | --- |
| P0 | 单头 32x32x64 attention tile | 打通 QK、softmax、PV |
| P1 | MHA，heads=9，head_dim=64 | 跑通可配置 seq_len |
| P2 | Re10K seq=576 实测 | 对齐 `up/down_blocks_2_*` |
| P3 | 流式 K/V tile + ping-pong | 给带宽优化实测 |
| P4 | GQA 扩展验证 | 共享 K/V heads，作为创新点 |

GQA 不建议作为第一版硬交付目标。更稳的做法是：寄存器和调度器从一开始
加入 `num_q_heads`、`num_kv_heads` 和 `group_size`，第一版配置成
`num_q_heads == num_kv_heads`，P4 再打开 `num_q_heads > num_kv_heads`。

## 1. 目标与评分策略

### 1.1 竞赛硬指标

| 项目 | 要求 | 推荐实现 |
| --- | --- | --- |
| Attention | 含 softmax | QK^T、softmax、PV 完整流水 |
| 矩阵阵列 | 大于 16x16 | 32x32 脉动阵列 |
| KV cache | 大于 4 KB | 流式 K/V tile cache，至少 128 KB |
| softmax 并行度 | 大于 16 | 32 lane |
| 输出接口 | AXI4 master | 输出矩阵 O burst 写回 |
| 输入/配置 | AXI4 slave | 寄存器 + 数据写入窗口 |
| FPGA 实现 | 可基于 FPGA | RTL + 综合 + 板级实测 |

### 1.2 得分导向

| 分项 | 分值 | 准备策略 |
| --- | --- | --- |
| 文件完整性 | 40 | RTL、SV 验证、设计文档、验证文档、PPT 全部闭环 |
| 架构与指标 | 30 | 给出阵列规模、带宽、cache、softmax、性能模型 |
| 实测数据 | 30 | 仿真、综合、板上运行、真实 Attention 子层数据 |

加分项应尽量用表格和曲线支撑：

- 带宽优化：有/无 ping-pong、burst、数据复用的吞吐对比。
- 可扩展性：seq_len、KV cache 深度、head/GQA 配置参数化。
- 数据复用：Q tile 复用 K/V tile，K/V 进入 KV cache 后多 query 复用。
- 单位算力功耗：记录 GOPS/W、有效 Attention token/s/W。
- 真实网络：运行真实 Transformer 中一层或多层 Attention 并给误差和耗时。

## 2. Attention 算法与数据格式

### 2.1 基本计算

单头 Attention：

```text
S = Q * K^T * scale
P = softmax(S)
O = P * V
scale = 1 / sqrt(head_dim)
```

基线支持参数：

- batch：第一版 batch=1，后续参数化到 4。
- num_q_heads：第一版固定 9，寄存器保留可配置字段。
- num_kv_heads：MHA 下等于 9，GQA 扩展时小于 num_q_heads。
- seq_q：16-bit 可配置，首测 576，验证到 1024。
- seq_kv：16-bit 可配置，首测 576，验证到 1024。
- head_dim：第一版固定 64。

`seq_len` 的边界分为三层：

| 类型 | 数值 | 含义 |
| --- | --- | --- |
| 架构上限 | 65535 | 由 16-bit seq 寄存器和 tile counter 决定 |
| 首版验证上限 | 1024 | UVM 回归和性能模型覆盖到该规模 |
| Re10K 实测点 | 576 | 对齐 `hidden=576` 的 attention block |

由于 K/V 采用 tile 流式读取，架构上限不受片上 KV cache 容量直接限制。更长
序列只会增加 tile 循环次数、外部带宽需求和总运行时间。

### 2.2 推荐数据格式

基线建议使用 INT8 GEMM + BF16/FP-like softmax 混合精度：

| 数据 | 格式 | 原因 |
| --- | --- | --- |
| Q/K/V 输入 | INT8 | 对齐 Re10K 量化模型，降低带宽和 cache 压力 |
| QK 累加 | INT32 | 避免 dot product 溢出 |
| scale 后 score | BF16 或 FP-like 16b | 进入 softmax 前统一指数域 |
| exp 输出 | BF16 或 FP-like 16b | 便于指数近似和归一化 |
| LSE/row_sum | FP-like 24b/32b | 降低 block-wise 累加误差 |
| O_acc | INT32 或 FP-like 32b | 支持在线归一化前的高精度累加 |
| 输出 O | INT8 或 INT16 | 首版 INT8 对齐 Re10K，INT16 便于误差分析 |

这里的 BF16 不表示全链路 BF16。MAC 阵列仍按 INT8 设计，BF16/FP-like 只用于
softmax、exp、block-wise LSE、倒数和在线归一化流水线。

为了答辩更稳，建议实现两套仿真参考：

1. bit-accurate 定点模型：用于 RTL 对拍。
2. Python/PyTorch 浮点模型：用于误差评估。

### 2.3 量化 scale 处理策略

Re10K 的 INT8 模型包含权重、激活 scale 和 zero-point。Attention 核心不能把
所有反量化都推迟到主机端，因为 softmax 前的 score 数值域必须正确。推荐做法是
主机端预融合 scale，PL 端只做定点乘法、移位、round 和 saturate。

主机端预计算：

```text
score_scale = q_scale * k_scale / sqrt(head_dim)
value_scale = v_scale
out_scale   = value_scale / o_scale
```

PL 端数据路：

```text
Q/K INT8 -> zero-point correction -> INT32 dot
INT32 dot * SCORE_SCALE_MANT >> SCORE_SCALE_SHIFT -> BF16/FP-like score
score -> mask -> exp -> block-wise LSE -> online softmax
P * V_INT8 -> O_acc
O_acc * OUT_SCALE_MANT >> OUT_SCALE_SHIFT -> O_INT8/O_INT16
```

硬件中不加入通用 FP32 计算单元。需要的是一个小型 `scale_requant_unit`：

- 支持 signed INT32 乘定点 mantissa。
- 支持可配置右移。
- 支持 round-to-nearest。
- 支持 INT8/INT16 饱和。
- 支持加 output zero-point。

第一版可以输出 INT16 或 FP-like O 便于对拍；性能版再打开 INT8 requantize，
使输出能直接接 Re10K 后续层。

### 2.4 在线 softmax 数据流

不推荐存储完整 S 或 P 矩阵。推荐 FlashAttention 风格在线 softmax，并把
exp、block-wise LSE、在线归一化和因果掩码做成一条流式流水线：

```text
score_masked = causal_mask ? -inf : score
m_new = max(m_old, max(score_masked_tile))
l_new = l_old * exp(m_old - m_new) + sum(exp(score_masked_tile - m_new))
O_acc_new =
    O_acc_old * exp(m_old - m_new) +
    sum(exp(score_masked_tile - m_new) * V_tile)
O = O_acc_final / l_final
```

优点：

- 不需要落地 N x N 注意力矩阵，显著减少片外访存。
- softmax 数值稳定，避免指数溢出。
- K/V tile 可在片上 cache 中复用。
- 因果掩码在 score 进入 max/exp 前完成，无效位置直接置为 -inf。
- 方便展示带宽优化数据。

## 3. 整体微架构

### 3.1 顶层框图

```text
AXI4 Slave
    |-- register file
    |-- input data window / write DMA sink
    v
+---------------- attention_accel_top ----------------+
| control_fsm / scheduler                             |
|                                                     |
| +-----------+    +-------------+    +-------------+ |
| | q_buffer  |    | k_cache     |    | v_cache     | |
| | ping-pong |    | banked SRAM |    | banked SRAM | |
| +-----------+    +-------------+    +-------------+ |
|       |                |                  |          |
|       v                v                  v          |
| +------------- os_fsa_systolic_array ------------+ |
| | 32x32 OS PE + row reduce + PWL exp + LSE       | |
| | QK, mask, rowmax, exp, rowsum, PV              | |
| +-------------------------------------------------+ |
|       |                                            |
|       v                                            |
| +-----------+    +---------------+                 |
| | o_buffer  | -> | AXI4 master   | -> output DDR   |
| +-----------+    +---------------+                 |
+-----------------------------------------------------+
```

### 3.2 推荐分块

推荐 tile 参数：

- Bq = 32：一次处理 32 个 query token。
- Bk = 32：一次处理 32 个 key/value token。
- D = 64：head_dim 常用基线。
- 阵列 = 32x32：适配 Bq x Bk 的 score tile。
- softmax lane = 32：一行 32 个 score 并行进入 row reduce/PWL 流水。

对 head_dim = 64：

1. Q tile 读入 32x64。
2. K tile 读入 32x64，计算 Q * K^T，得到 32x32 score tile。
3. softmax_engine 对每个 query 行更新 m、l、O_acc。
4. V tile 读入 32x64，计算概率权重乘 V。
5. 遍历所有 K/V tile 后，对 O_acc 做除法归一化并写回。

### 3.3 FSA-Inspired OS 脉动阵列设计

推荐采用借鉴 SystolicAttention/FSA 的 32x32 output-stationary 阵列。该设计
不照搬论文中的 weight-stationary 基线，而是保留本项目 OS 数据流，同时吸收
FSA 的三个思想：

1. 在阵列内完成 rowmax/rowsum，减少 score/prob 往返 SRAM。
2. PE 增加减法、比较选择和 PWL exp 所需的轻量 datapath。
3. 通过行/列方向的 restream 通路把 row state 广播回 PE。

这样做是合理的：本项目的 QK tile 正好是 `32x32` score tile，OS PE 可以在
QK 结束后短暂保存每个 `S[i][j]`，随后在同一阵列附近完成 mask、rowmax、
`S - m`、exp、rowsum，再把 probability stream 送入 PV 模式。相比“普通
MAC 阵列 + 外部 softmax_engine”，该方案更贴近 FlashAttention 的 in-place
数据复用，也更容易在答辩中体现硬件创新。

#### 3.3.1 OS 数据映射

QK 模式：

- PE 行对应 `query` tile 的 32 个 token。
- PE 列对应 `key` tile 的 32 个 token。
- 每个 PE output-stationary 累加一个 `S[i][j]`。
- `head_dim=64` 时，PE 对 64 个 INT8 乘加做 INT32 累加。

PV 模式：

- PE 行仍对应 32 个 query token。
- PE 列对应 V/O 的 32 个 feature 维度。
- `head_dim=64` 分两轮，每轮计算 32 个输出维度。
- 每个 PE output-stationary 累加一个 `O_tile[i][d]`。

#### 3.3.2 OS-FSA PE 功能

每个 PE 保留原有 MAC 能力，并增加轻量模式选择：

| 模式 | 功能 | 用途 |
| --- | --- | --- |
| MAC_INT8 | `acc += a_int8 * b_int8` | QK 和 PV 主计算 |
| SUB | `x - row_value` | 计算 `S - m_new` |
| MAX_PASS | 比较/旁路 | 支持行归约 rowmax |
| ADD_PASS | 加法/旁路 | 支持 rowsum 和 LSE 更新 |
| PWL_EXP | 分段线性 exp2 近似 | 计算 probability |
| SCALE | 定点乘移位 | score scale 和输出 requant |

PE 内部寄存器建议：

- `a_reg`、`b_reg`：输入数据寄存。
- `acc_reg`：OS 累加寄存器。
- `score_reg`：QK 后的 score 暂存，可与 `acc_reg` 复用。
- `prob_reg`：exp 后的 probability 暂存或流式输出寄存。
- `mode_reg`、`valid_reg`：模式和有效位流水。

PWL exp 不建议首版做完整浮点单元。推荐将 `x <= 0` 的输入转为定点或
BF16-like 表示，用 8 到 16 段 PWL，系数由小 ROM 或常量寄存器提供。论文中
FSA 使用 PWL exp2 并利用输入非正的性质；本项目可采用相同思想，但位宽按
BF16/FP-like softmax 精度重新定点化。

#### 3.3.3 行归约与 restream 通路

由于 OS 映射下 `S[i][j]` 的同一行对应同一个 query token，rowmax/rowsum
推荐按“行归约”实现：

- 每一 PE 行配置一个 `row_reduce_unit`。
- QK 完成后，32 个 `score_reg` 横向进入 rowmax 归约树。
- `m_new` 写入 `row_state[i]`，并沿行广播回 32 个 PE。
- PE 执行 `score_reg - m_new`，再进入 PWL exp。
- exp 后的 32 个 probability 横向进入 rowsum 归约树。
- `l_new` 更新到 `row_state[i]`，probability 同时进入 PV 数据通路。

该设计与论文的 upward data path/comparator array 作用类似，但方向按 OS
映射调整为行归约和行广播。这样不需要把 score tile 写入 BRAM，也不需要外部
vector/scalar softmax 单元。

#### 3.3.4 调度顺序

单个 `Q tile x K/V tile` 内部调度：

```text
1. OS_QK_MAC:
       PE[i][j] accumulates S[i][j]
2. CAUSAL_MASK:
       invalid S[i][j] = -inf
3. ROW_MAX:
       row_reduce_unit computes block_max[i]
4. ROW_RESCALE:
       m_new = max(m_old, block_max)
       PE[i][j] computes S[i][j] - m_new
5. PWL_EXP:
       PE computes exp(S[i][j] - m_new)
6. ROW_SUM:
       row_reduce_unit computes block_sum[i]
       row_state updates l_new
7. OS_PV_MAC:
       probability stream and V tile compute O_acc
8. FINAL_NORM:
       after all K/V tiles, O_acc *= reciprocal(l_final)
```

首版实现可以让 QK、softmax、PV 以 tile 内阶段化方式执行；后续再参考
SystolicAttention 做更细粒度 overlap。这样风险较低，同时保留可扩展优化空间。

#### 3.3.5 与原方案的取舍

| 项目 | 原普通阵列方案 | OS-FSA 阵列方案 |
| --- | --- | --- |
| QK/PV | 32x32 MAC 阵列 | 32x32 OS 多模式 PE 阵列 |
| softmax | 外部 32 lane engine | 行归约 + PE PWL exp |
| S/P 存储 | score/prob stream FIFO | PE 内暂存 + stream |
| 创新性 | 中等 | 更强，贴近 SystolicAttention |
| 实现风险 | 低 | 中等 |
| 首版建议 | 可作为 fallback | 作为主线设计 |

风险控制：

- 保留 `softmax_engine` 模块边界，但内部实现映射到 OS-FSA array side units。
- 首版先实现阶段化 QK -> rowmax/exp/rowsum -> PV。
- overlap 调度作为 P3/P4 优化，不影响 P0/P1 功能闭环。

### 3.4 可重构计算备选

若 FPGA DSP 很紧张，可做 16x32 或 32x16 阵列，但必须保证任一维均大于 16
或总阵列明确为 32x32 逻辑阵列。推荐仍以 32x32 为答辩主线。

可重构点：

- QK 模式：输入 A=Q，B=K^T，输出 score。
- PV 模式：输入 A=P，B=V，输出 O_acc。
- GEMM 通用接口保留，便于展示可扩展性。

## 4. 多级缓存与 KV Cache

### 4.1 缓存层次

| 层级 | 容量建议 | 器件类型 | 存储内容 | 用途 |
| --- | --- | --- | --- | --- |
| L0 PE regs | 阵列内部 | 寄存器 | 当前 a/b/psum | MAC 流水 |
| L0 row_state | 32 行状态 | 寄存器 | m、l、scale | 在线 softmax |
| L1 q_buffer | 2 x 32x64x8b | BRAM 或寄存器 | Q tile | ping-pong |
| L1 score_fifo | 32 lane 流水 | 寄存器/FIFO | score 流 | softmax 输入 |
| L1 p_fifo | 32 lane 流水 | 寄存器/FIFO | 概率流 | PV 输入 |
| L1 o_buffer | 32x64x32b | BRAM | O_acc/O | 输出累加 |
| L2 k_tile_cache | >= 64 KB | URAM 优先 | K tile 流水缓存 | 当前/下一 tile |
| L2 v_tile_cache | >= 64 KB | URAM 优先 | V tile 流水缓存 | 当前/下一 tile |

推荐第一版至少实现 128 KB streaming KV tile cache。它不是为了缓存完整
K/V 序列，而是作为当前/下一 K/V tile 的片上多 bank、ping-pong 缓冲。这样既
远高于赛题 4 KB 硬指标，又不会让 `seq_len` 上限受片上 cache 容量限制。

128 KB streaming KV tile cache 例子：

```text
K tile cache = 64 KB
V tile cache = 64 KB
INT8 数据下可容纳多个 32x64 K/V tile，并支持 ping-pong 和 bank 并行。
长序列从外部内存按 tile 流式读取，不要求完整 K/V 常驻片上。
```

对 MHA 第一版，推荐按 head 粒度或小 head group 调度：每次处理一个或一组
heads，对应 K/V cache 只保存当前流式 tile。对 GQA 扩展，K/V tile cache 的
head 维度改为 `num_kv_heads`，多个 Q heads 复用同一组 K/V tile。

### 4.2 Bank 设计

推荐 streaming K/V tile cache 使用多 bank URAM，外面包一层 `banked_sram`
模块。这样首版在 Xilinx 工具中推断 URAM，后续迁移 DC 时可替换为 SRAM
macro wrapper。

- bank 数：8 或 16，优先 16 bank 匹配 128-bit AXI。
- 每 bank 位宽：64 bit 或 128 bit。
- 地址映射：按 dim 低位交错，保证并行读取 D 维数据。
- 支持 burst 写入：host 通过 AXI slave 写入 cache。

器件选择原则：

- URAM：streaming K/V tile cache、多 bank ping-pong 缓冲。
- BRAM：Q tile、O tile、较小的 ping-pong buffer。
- 寄存器：PE 内部、softmax 行状态、归约树流水、短 FIFO。
- 不落地 RAM：完整 S/P 矩阵不写 BRAM/URAM，只在 score/prob 流水中经过。

地址映射建议：

```text
addr = base + (((token_id * head_dim + dim_id) * bytes_per_elem))
bank = dim_id % num_banks
row = (token_id * head_dim + dim_id) / num_banks
```

### 4.3 Streaming KV 管理策略

第一版采用 prefill-style 的流式 tile 模式：

```text
for q_tile in seq_q:
    load Q tile
    init row m/l/O_acc
    for kv_tile in seq_kv:
        stream K tile into k_tile_cache
        stream V tile into v_tile_cache
        compute QK, softmax update, PV update
    normalize and write O tile
```

在该模式下，片上 KV cache 不保存完整历史 token；`seq_len` 的实际上限主要由
外部地址空间、计数器位宽、运行时间和软件调度决定。

寄存器应包含：

- K_BASE、V_BASE：外部 K/V 数据基地址或输入窗口偏移。
- SEQ_Q、SEQ_KV：16-bit 序列长度。
- TILE_Q、TILE_K：tile 尺寸，第一版为 32。
- KV_TILE_STRIDE：相邻 K/V tile 的地址步长。
- KV_MODE：第一版为 streaming prefill。

Decode 模式可以后续扩展为 circular KV cache，但不作为第一版基线。

### 4.4 MHA 到 GQA 的扩展接口

第一版 MHA：

```text
num_q_heads = num_kv_heads = num_heads
q_head_id   = kv_head_id
```

GQA 扩展：

```text
group_size  = num_q_heads / num_kv_heads
kv_head_id  = q_head_id / group_size
```

需要从第一版开始预留的寄存器：

- NUM_Q_HEADS：Q head 数。
- NUM_KV_HEADS：K/V head 数。
- HEAD_DIM：第一版为 64。
- HEAD_STRIDE_Q：Q head 间地址步长。
- HEAD_STRIDE_KV：K/V head 间地址步长。
- GQA_ENABLE：第一版置 0，扩展时置 1。

这样第一版 MHA 不增加额外调度复杂度，后续 GQA 只改 head 映射和 K/V
cache 复用关系。

## 5. Softmax 近似与并行实现

在 OS-FSA 主线中，`softmax_engine` 不是外置向量单元，而是 OS-FSA 阵列侧的
控制封装：causal mask、rowmax、PWL exp、rowsum 和 LSE 更新由 PE 多模式、
`row_reduce_unit`、`row_broadcast` 和 `row_state` 协同完成。这样可以减少
score/prob 在阵列和外部 SRAM 之间往返。

### 5.1 单流水线 softmax/LSE/归一化

softmax_engine 推荐做成一条 32 lane 流水线，覆盖：

```text
score -> causal mask -> row max -> exp -> block-wise LSE
      -> row_sum update -> reciprocal -> online O_acc update
```

每个 query 行只维护少量行状态，放在寄存器中：

- `m`：历史 block 的 row max。
- `l`：历史 block 的 exp sum。
- `inv_l`：归一化倒数，可流水延迟后写回。
- `O_acc`：在线输出累加，存放在 BRAM o_buffer 中。

score tile 到达后：

1. 因果掩码先处理非法位置，masked score 直接置为 `-inf`。
2. 32 lane 并行求当前 block 的 `block_max`。
3. 计算 `m_new = max(m_old, block_max)`。
4. 32 lane 并行计算 `exp(score_masked - m_new)`。
5. 树形归约得到 `block_sum`，并更新 block-wise LSE 状态。
6. 计算 `alpha = exp(m_old - m_new)`，更新 `l_new`。
7. 概率流直接进入 PV 路径，同时用 `alpha` 重标定旧 `O_acc`。
8. 最后用 `reciprocal(l_final)` 完成在线归一化。

这个设计不写完整 S/P RAM。S 只以 score stream 形式进入 softmax，P 只以
probability stream 形式进入 PV。需要保存的只有行状态寄存器和 O_acc buffer。

### 5.2 指数近似方案

推荐两级近似，兼顾误差和实现复杂度：

```text
x <= 0
exp(x) = 2^(x / ln2)
x / ln2 = n + f
exp(x) = 2^n * 2^f
```

实现：

- n：整数部分，用移位实现。
- f：小数部分，使用 256 项 LUT 或 16 段 PWL。
- 输入范围：[-16, 0] 或 [-8, 0]，小于下限直接近似为 0。
- 输出格式：BF16 或 FP-like 16b，指数域与 LSE 状态对齐。

对比方案：

| 方案 | 资源 | 误差 | 建议 |
| --- | --- | --- | --- |
| 纯 LUT | BRAM/LUT 中等 | 低 | 首版容易验证 |
| PWL | LUT 少 | 中 | 适合资源优化 |
| 二次多项式 | DSP 增加 | 低 | 可作为优化版 |

推荐首版：256-entry LUT + 线性插值。PPT 中展示误差曲线。LUT 可用 BRAM
或 distributed ROM，小表优先 distributed ROM，避免占用 K/V cache 的 URAM。

### 5.3 除法/倒数

归一化 O = O_acc / l 可使用：

- 16-bit reciprocal LUT 初值。
- 1 次 Newton-Raphson 迭代。
- 或直接定点除法流水线。

为了缩短实现周期，推荐先用 reciprocal LUT + 乘法。

倒数流水线输出 `inv_l` 后，与 O_acc 读出对齐。这样归一化阶段只做乘法，
不在主数据通路中放慢速除法器。

### 5.4 并行度证明

文档中明确写：

- OS-FSA 阵列提供 32 个并行 score lane。
- 每行 32 个 score 同时进入 rowmax/rowsum 归约。
- PWL_EXP 为多周期流水，延迟由 PWL 段数和定点/BF16-like 格式决定。
- 设计指标统计吞吐和流水延迟，而不是声称 exp 单拍完成。

## 6. AXI4 接口与寄存器设计

### 6.1 接口划分

AXI4 slave：

- 寄存器配置。
- Q/K/V 输入数据写入窗口。
- 状态读取。
- 中断状态读取/清除。

AXI4 master：

- 输出 O 写回外部内存。
- 支持 burst write。
- 输出地址、stride、长度由寄存器配置。

若规则允许 master read，可增加 master 读输入以提高可用性；若不允许，则保持
slave 写输入、master 写输出的纯合规方案。

### 6.2 寄存器表

| Offset | Name | R/W | 描述 |
| --- | --- | --- | --- |
| 0x000 | CTRL | R/W | bit0 start，bit1 soft_reset，bit2 irq_en |
| 0x004 | STATUS | R | bit0 busy，bit1 done，bit2 error |
| 0x008 | CONFIG0 | R/W | data_type，mode，gqa_enable |
| 0x00C | CONFIG1 | R/W | seq_q，16-bit，最大 65535 |
| 0x010 | CONFIG2 | R/W | seq_kv，16-bit，最大 65535 |
| 0x014 | CONFIG3 | R/W | head_dim，首版必须为 64 |
| 0x018 | CONFIG4 | R/W | tile_q，tile_k |
| 0x01C | MASK_CFG | R/W | bit0 causal_enable |
| 0x020 | NUM_Q_HEADS | R/W | Q head 数，MHA 下等于 K/V head 数 |
| 0x024 | NUM_KV_HEADS | R/W | K/V head 数，GQA 下小于 Q head 数 |
| 0x028 | GROUP_SIZE | R/W | GQA 分组大小，MHA 下为 1 |
| 0x02C | Q_BASE | R/W | slave 输入窗口中 Q 偏移 |
| 0x030 | K_BASE | R/W | slave 输入窗口中 K 偏移 |
| 0x034 | V_BASE | R/W | slave 输入窗口中 V 偏移 |
| 0x038 | O_BASE_LO | R/W | AXI master 输出低 32 位地址 |
| 0x03C | O_BASE_HI | R/W | AXI master 输出高 32 位地址 |
| 0x040 | STRIDE_Q | R/W | Q stride |
| 0x044 | STRIDE_KV | R/W | K/V stride |
| 0x048 | STRIDE_O | R/W | O stride |
| 0x04C | SCORE_SCALE_MANT | R/W | q_scale * k_scale / sqrt(d) 尾数 |
| 0x050 | SCORE_SCALE_SHIFT | R/W | score scale 右移量 |
| 0x054 | OUT_SCALE_MANT | R/W | value_scale / output_scale 尾数 |
| 0x058 | OUT_SCALE_SHIFT | R/W | output requant 右移量 |
| 0x05C | ZERO_POINT_CFG0 | R/W | q_zp、k_zp、v_zp、o_zp |
| 0x060 | KV_TILE_STRIDE | R/W | 相邻 K/V tile 地址步长 |
| 0x064 | MAX_SEQ_CFG | R/W | 软件声明的测试/保护上限 |
| 0x068 | PERF_CYCLE | R | 总周期 |
| 0x06C | PERF_MAC | R | 有效 MAC 计数 |
| 0x070 | PERF_AXI_STALL | R | AXI 等待周期 |
| 0x074 | PERF_SOFTMAX_STALL | R | softmax 等待周期 |
| 0x078 | ERROR_CODE | R | 参数错误、溢出等 |
| 0x100 | INPUT_WINDOW | W | Q/K/V 数据写入窗口起始 |

### 6.3 启动流程

```text
1. Host 通过 AXI slave 写 Q，K/V 由输入窗口或流式 tile 方式提供。
2. Host 配置维度、stride、scale mantissa/shift、zero-point、输出地址。
3. Host 写 CTRL.start = 1。
4. Accelerator 拉起 busy，调度 tile 循环。
5. AXI master burst write 输出 O。
6. STATUS.done = 1，可选产生中断。
```

## 7. 控制与数据流调度

### 7.1 顶层状态机

```text
IDLE
  -> LOAD_CONFIG
  -> LOAD_Q_TILE
  -> LOAD_KV_TILE
  -> COMPUTE_QK
  -> SOFTMAX_UPDATE
  -> COMPUTE_PV
  -> NEXT_KV_TILE
  -> NORMALIZE_O
  -> WRITE_O
  -> NEXT_Q_TILE
  -> DONE
```

### 7.2 Ping-Pong 缓冲

对 Q/K/V/O 关键路径使用 ping-pong：

- 当前 tile 计算时，下一 tile 从 AXI slave 写入或从 cache 预取。
- 输出 O 写回时，下一 Q tile 可开始计算。
- 记录有/无 ping-pong 的 stall 周期，作为带宽优化数据。

### 7.3 数据复用

复用路径：

- Q tile 在遍历所有 K/V tile 时保持在 q_buffer。
- K tile 同时用于多个 Q row 的 QK 计算。
- V tile 在 PV 阶段复用同一个 K tile 对应的概率。
- streaming K/V tile cache 通过 ping-pong 复用当前/下一 tile。

文档中建议给出片外访问量对比：

```text
Naive:
    读 Q/K/V + 写 S + 读 S + 写 P + 读 P + 写 O

FlashAttention-like:
    读 Q/K/V + 写 O
    S 和 P 只在流水中经过，不落地 BRAM/URAM
```

## 8. 模块划分

建议 RTL 目录结构：

```text
rtl/
    attention_accel_top.sv
    control/
        accel_regfile.sv
        accel_scheduler.sv
        perf_counter.sv
    axi/
        axi4_slave_if.sv
        axi4_master_write.sv
    compute/
        os_fsa_array.sv
        os_fsa_pe.sv
        os_fsa_controller.sv
        scale_requant_unit.sv
        qk_engine.sv
        pv_engine.sv
    softmax/
        softmax_engine.sv
        row_reduce_unit.sv
        row_broadcast.sv
        causal_mask.sv
        pwl_exp_unit.sv
        block_lse_update.sv
        reciprocal_lut.sv
        online_normalizer.sv
    memory/
        pingpong_buffer.sv
        banked_sram.sv
        uram_bank.sv
        bram_buffer.sv
        kv_cache.sv
        stream_fifo.sv
        output_buffer.sv
    common/
        fixed_pkg.sv
        attention_pkg.sv
```

验证目录：

```text
sim/
    tb/
        tb_attention_accel_top.sv
        axi_master_bfm.sv
        axi_slave_bfm.sv
        scoreboard.sv
        coverage.sv
    vectors/
        generate_vectors.py
        reference_model.py
    tests/
        test_smoke.sv
        test_softmax_accuracy.sv
        test_tile_boundary.sv
        test_axi_backpressure.sv
        test_random_attention.sv
docs/
    design.md
    verification.md
    report_data/
ppt/
    defense_outline.md
```

## 9. 开发流程

### 9.0 工具链与机器分工

推荐从当前有 Vivado/Vitis 的机器开始建工程、写 RTL 和做 Xilinx 综合。原因是
目标平台为 VCK190，早期必须尽快确认 RTL 可被 Xilinx 工具接受、BRAM/URAM/
DSP 推断方式正确、AXI 接口能进入 block design 或 Vitis kernel 流程。

另一台有 VCS 和 DC 的机器作为主验证与后端可迁移性机器：

| 任务 | 推荐机器 | 工具 | 目的 |
| --- | --- | --- | --- |
| RTL 编写和目录搭建 | Vivado 机器 | 编辑器 + lint | 快速迭代 |
| 早期 smoke 仿真 | Vivado 机器 | xsim | 检查语法和简单波形 |
| 主验证环境 | VCS/DC 机器 | VCS + UVM | 随机验证、覆盖率、回归 |
| FPGA 综合实现 | Vivado 机器 | Vivado/Vitis | 资源、频率、上板 |
| ASIC 迁移检查 | VCS/DC 机器 | DC | 综合可迁移性和时序参考 |

因此推荐流程是：

1. 在 Vivado 机器开始工作，先完成 RTL 骨架、package、接口和基本 smoke。
2. 同步代码到 VCS/DC 机器，建立 UVM 环境并把它作为功能 sign-off 标准。
3. 每个稳定里程碑同时跑 VCS 回归和 Vivado 综合，避免后期才发现不可综合。
4. DC 不作为第一版功能调试工具，只在 RTL 稳定后做 ASIC 风格综合检查。

如果两台机器不能共享文件系统，建议从第一天就使用 git 作为唯一同步方式，
不要手工拷贝散文件。测试向量和小规模 golden 数据可以入库，大规模 Re10K
dump 只记录路径和生成脚本。

### 9.1 里程碑

| 阶段 | 目标 | 产出 |
| --- | --- | --- |
| M1 | 定点模型 | Python reference、误差评估 |
| M2 | 单模块 RTL | PE、array、softmax、cache 单测 |
| M3 | Attention tile | QK + softmax + PV 单 tile 仿真 |
| M4 | 顶层集成 | AXI slave 配置、master 写回 |
| M5 | 随机验证 | 多维度、多 seed、覆盖率 |
| M6 | 综合实现 | 资源、频率、时序报告 |
| M7 | 板级实测 | 吞吐、功耗、带宽、真实网络 |
| M8 | 文档答辩 | 设计文档、验证文档、PPT |

### 9.2 推荐实现顺序

1. Python bit-accurate 模型和测试向量生成。
2. softmax_engine 单元 RTL 与对拍。
3. systolic_array 单元 RTL 与 GEMM 对拍。
4. kv_cache、pingpong_buffer、banked_sram。
5. tile_scheduler 串接 QK、softmax、PV。
6. AXI slave 寄存器与输入窗口。
7. AXI master writeback。
8. perf_counter 与功耗/带宽采样辅助。

## 10. 验证策略

主验证环境建议使用 UVM。原因是本项目风险不只在数值计算，也在 AXI 协议、
寄存器配置、tile 调度、backpressure、异常配置和覆盖率闭环。纯 directed
test 很难充分覆盖这些状态组合。

### 10.1 验证目标

- 功能正确：输出与参考模型误差在阈值内。
- 边界正确：不同 seq_len、head_dim、tile 尾块。
- AXI 正确：burst、backpressure、unaligned/非法配置。
- 性能可观测：周期计数、stall 计数、有效 MAC 计数。
- 覆盖完整：寄存器、状态机、tile 尺寸、异常路径。

### 10.2 Testcase 规划

UVM 环境建议包含：

- `attention_env`：顶层 environment。
- `axi_lite_agent`：寄存器配置和状态读取。
- `axi_stream_agent` 或 `axi_mem_agent`：输入数据和输出写回事务。
- `attention_sequencer`：生成维度、head、tile 和数据事务。
- `attention_scoreboard`：调用 Python/C DPI 或预生成 golden 对拍。
- `attention_coverage`：收集寄存器、维度、AXI backpressure 和状态覆盖。
- `attention_reference_model`：bit-accurate 定点参考模型。

验证分层建议：

1. 模块级 directed test：softmax、PE、array、KV cache。
2. 子系统 UVM test：单 head tile、AXI backpressure、非法配置。
3. 顶层 UVM regression：MHA、Re10K 维度、随机 seed、覆盖率。
4. Vivado xsim smoke：只保留少量测试，服务 FPGA 工程集成。

| 用例 | 内容 | 期望 |
| --- | --- | --- |
| smoke | seq_q=32，seq_kv=32，D=64 | 完整跑通 |
| small_debug | 4x4x8，禁用近似或高精 LUT | 易人工检查 |
| softmax_accuracy | 随机 score、极值 score | 误差达标，无溢出 |
| os_fsa_pe_modes | MAC/SUB/MAX/ADD/PWL/SCALE | PE 多模式切换正确 |
| row_reduce | rowmax、rowsum、broadcast | 行归约和广播对拍 |
| qk_gemm | 只测 QK | 与 numpy GEMM 对拍 |
| pv_gemm | 只测 PV | 与 numpy GEMM 对拍 |
| tile_boundary | seq 非 32 整数倍 | mask 正确 |
| kv_cache_prefill | 多个 K/V tile | cache 读写正确 |
| kv_cache_decode | 逐 token 更新 | write_ptr 正确 |
| axi_backpressure | 随机 ready/valid 停顿 | 无数据丢失 |
| illegal_config | head_dim=0、seq 超限等 | error_code 正确 |
| random_regression | 多 seed 随机维度 | 长时间稳定 |
| transformer_layer | 真实网络 Attention 输入 | 误差和性能统计 |

### 10.3 Scoreboard

Scoreboard 输入：

- 寄存器配置。
- Q/K/V 输入向量。
- RTL 输出 O。
- Python 参考输出 O_ref。

比较指标：

- max_abs_error。
- mean_abs_error。
- cosine_similarity。
- top-k token 或 attention row 分布误差。

建议验收阈值：

- INT8 输出：平均绝对误差小于 1 到 2 LSB。
- INT16 输出：相对误差小于 1e-2。
- Attention row sum 接近 1，误差小于 1e-2。

### 10.4 覆盖率

功能覆盖点：

- data_type。
- seq_q 桶：小于 32、等于 32、大于 32、非整除。
- seq_kv 桶：小于 32、等于 32、大于 32、非整除。
- head_dim：首版固定 64，非法值触发配置错误。
- AXI backpressure：无、中等、高。
- KV mode：prefill、decode。
- softmax 输入范围：正常、全负、单峰、全相等、极值。
- OS-FSA PE mode：MAC、SUB、MAX_PASS、ADD_PASS、PWL_EXP、SCALE。
- row_reduce：rowmax、rowsum、causal mask 后归约。

代码覆盖：

- line coverage。
- branch coverage。
- FSM state/transition coverage。
- toggle coverage，辅助功耗分析。

## 11. 性能评估方法

### 11.1 理论算力

32x32 阵列每周期执行：

```text
MAC/cycle = 32 * 32 = 1024
Ops/cycle = 2048  // 1 MAC = 2 ops
Peak GOPS = 2048 * freq_MHz / 1000
```

例如 200 MHz：

```text
Peak GOPS = 2048 * 200 / 1000 = 409.6 GOPS
```

### 11.2 Output-Stationary 阵列利用率

32x32 output-stationary 脉动阵列的单 tile MAC 利用率按有效 MAC 占阵列峰值
周期计算：

```text
util = useful_MACs / (array_PEs * total_cycles)
```

对 `M x K` 乘 `K x N`，单个 output-stationary tile 的周期近似为：

```text
cycles = K + M + N - 2
util   = K / (K + M + N - 2)
```

该公式反映了脉动阵列 fill/drain 开销。对本项目基线：

```text
array = 32x32
Bq = 32
Bk = 32
head_dim = 64
```

QK 阶段：

```text
Q tile  = 32 x 64
K tile  = 32 x 64
QK^T    = 32 x 64 * 64 x 32
M = 32, N = 32, K = 64
cycles = 64 + 32 + 32 - 2 = 126
useful_MACs = 32 * 32 * 64 = 65536
peak_MACs   = 32 * 32 * 126 = 129024
util = 65536 / 129024 = 50.8%
```

PV 阶段：

```text
P tile = 32 x 32
V tile = 32 x 64
```

32x32 阵列一次计算 32 个输出维度，`head_dim=64` 需要分两轮。每轮：

```text
M = 32, N = 32, K = 32
cycles = 32 + 32 + 32 - 2 = 94
util = 32 / 94 = 34.0%
```

两轮 PV 合计仍约为 `34.0%`。若 QK 和 PV 的有效 MAC 数相同，单 tile 粗略
整体利用率为：

```text
overall_util = (65536 + 65536) / (1024 * (126 + 188))
             = 131072 / 321536
             = 40.8%
```

| 阶段 | 计算 | 单 tile 利用率 |
| --- | --- | --- |
| QK | `32x64 * 64x32` | 约 50.8% |
| PV | `32x32 * 32x64`，分两轮 | 约 34.0% |
| QK+PV | 单 tile 粗略平均 | 约 40.8% |

该利用率是保守的 MAC-only 单 tile 估算，未计入 OS-FSA 中 PE 执行 SUB、
PWL_EXP、rowsum 等 softmax 模式时的有效工作周期。改成 OS-FSA 后，报告中
建议同时给出两类指标：

- `mac_utilization`：只统计 QK/PV MAC 的有效利用率。
- `array_active_utilization`：统计 MAC、SUB、PWL_EXP、row reduction 等
  所有阵列内有效工作周期。

连续 tile 流水可进一步摊薄 fill/drain。后续可通过以下方式提升有效利用率：

- 连续处理多个 K/V tile，减少阵列空泡。
- 对多个 head 或 head group 串流调度，增加阵列连续工作时间。
- 增大有效 K 维或合并 PV 输出维度，摊薄 `M + N - 2` 开销。
- 用 ping-pong buffer 隐藏 K/V tile 载入和 O 写回等待。

### 11.3 Attention 运算量

单头近似：

```text
QK MACs = seq_q * seq_kv * head_dim
PV MACs = seq_q * seq_kv * head_dim
Total MACs = 2 * seq_q * seq_kv * head_dim
Softmax ops ~= seq_q * seq_kv * (exp + reduce + div)
```

性能指标：

- latency_cycles。
- latency_us。
- tokens/s。
- effective GOPS。
- array_utilization = effective MAC / peak MAC。
- bandwidth_efficiency = valid_axi_bytes / total_cycles。

### 11.4 带宽评估

记录：

- AXI 写输出字节数。
- 输入写入字节数。
- K/V tile 复用次数和 ping-pong 覆盖率。
- AXI stall 周期。

对比实验：

1. 无 ping-pong vs 有 ping-pong。
2. 无 ping-pong K/V tile vs streaming ping-pong K/V tile。
3. 存 S/P 到外部内存 vs 片上在线 softmax。

## 12. 功耗优化与实测

### 12.1 RTL 级优化

- clock enable：PE 无 valid 时停止寄存器翻转。
- operand gating：输入为 0 或 mask 时跳过 MAC。
- bank enable：只打开当前 tile 需要的 SRAM bank。
- pipeline valid gating：无效尾块不传播无意义数据。
- mode gating：QK/PV 只启用当前模式相关路径。

### 12.2 系统级优化

- 降低 AXI stall：burst 对齐、较大 burst length、ping-pong 缓冲。
- 提升阵列利用率：tile_q/tile_k 与 32x32 阵列匹配。
- 降低外存访问：S/P 不落地，K/V tile 流式复用。
- 可选 DVFS：若板卡支持，记录不同频率/电压下 GOPS/W。

### 12.3 实测数据表

建议最终报告包含：

| 配置 | 频率 | 资源 | 功耗 | 延迟 | GOPS | GOPS/W |
| --- | --- | --- | --- | --- | --- | --- |
| baseline | 150 MHz | 待测 | 待测 | 待测 | 待测 | 待测 |
| first target | 200 MHz | 待测 | 待测 | 待测 | 待测 | 待测 |
| ping-pong | 200 MHz | 待测 | 待测 | 待测 | 待测 | 待测 |
| optimized | 200 MHz | 待测 | 待测 | 待测 | 待测 | 待测 |

功耗来源：

- 板卡电源监控芯片。
- Vivado/XPower 基于 SAIF/VCD 的估计。
- 外接功率计，记录 idle 和 running 差值。

单位算力功耗：

```text
dynamic_power = running_power - idle_power
GOPS/W = effective_GOPS / dynamic_power
```

## 13. 真实 Transformer 网络实验

### 13.1 推荐网络

推荐以 Re10K 的 transformer attention 子层作为真实网络实验。当前路径中已有
INT8 权重、量化参数和 attention dump：

```text
/home/project/public_fpga/FPGA25_ARIES_AE/dfot_fpga/dfot_test/aie_bins
/home/project/public_fpga/FPGA25_ARIES_AE/dfot_fpga/dfot_test/attention
```

首版建议分三档验证：

1. Core tile：`Bq=32`、`Bk=32`、`head_dim=64`，用于 RTL 快速回归。
2. 可配置序列：`seq_len=32/64/144/576`，验证尾块和调度。
3. Re10K 首测：`seq=576`、`hidden=576`、`heads=9`、`head_dim=64`。

真实网络接入顺序：

1. 使用已有 Q、KT、V dump 对 QK、softmax、PV 分段对拍。
2. 使用已有 prob 和 V dump 验证 PV 子路径，隔离 softmax 误差。
3. 跑完整 QK + softmax + PV，输出与软件参考比较。
4. 可选接 attention output projection，形成更完整的 attention block。

### 13.2 实测指标

- 单层 Attention 延迟。
- 与 CPU/PyTorch baseline 的延迟对比。
- 输出误差：max_abs_error、mean_abs_error、cosine_similarity。
- Re10K 子层误差：与已导出 dump 或 Python reference 比较。

## 14. 设计文档结构

建议 `docs/design.md` 包含：

1. 需求解读与指标表。
2. 算法与定点格式。
3. 顶层架构图。
4. 数据流和 tile 调度。
5. 脉动阵列设计。
6. softmax 近似与误差分析。
7. KV cache 与多级缓存。
8. AXI 接口和寄存器定义。
9. 资源、频率、带宽、功耗分析。
10. 实测结果。
11. 设计小结与待改进之处。

## 15. 验证文档结构

建议 `docs/verification.md` 包含：

1. 验证目标。
2. 验证环境框图。
3. 参考模型说明。
4. testcase 列表和覆盖需求。
5. testcase 结果表。
6. 功能覆盖率和代码覆盖率。
7. bug 列表与修复记录。
8. 遗留风险。

## 16. 答辩 PPT 要点

推荐 12 到 15 页：

1. 赛题要求与完成度总览。
2. 关键指标一页表：32x32、128 KB streaming KV、32 lane softmax、AXI4。
3. Attention 算法与 FlashAttention-like 数据流。
4. 顶层微架构图。
5. 32x32 脉动阵列设计。
6. 在线 softmax 与指数近似误差。
7. 多级缓存和 streaming KV tile cache。
8. AXI4 接口和寄存器启动流程。
9. 带宽优化：ping-pong、burst、片上 S/P。
10. 数据复用和可扩展性。
11. 资源、频率、时序报告。
12. 功耗与 GOPS/W。
13. 真实 Transformer Attention 实测。
14. 验证环境、testcase、覆盖率。
15. 总结与后续改进。

答辩时重点强调：

- 不是只做 GEMM，而是完整 QK + softmax + PV。
- softmax 是硬件并行加速，且并行度大于 16。
- S/P 不落地，访存显著减少。
- 实测数据覆盖性能、功耗、误差、资源。

## 17. 风险与降级方案

| 风险 | 影响 | 降级方案 |
| --- | --- | --- |
| 32x32 阵列资源不足 | 时序或资源失败 | 降频，或时间复用 DSP，但保留逻辑阵列说明 |
| softmax 误差偏大 | 真实网络精度差 | 增大 LUT，使用线性插值或 NR 倒数 |
| AXI slave 输入带宽不足 | 性能差 | 增加输入 staging，扩大 ping-pong，报告瓶颈 |
| decode 模式来不及 | 功能缺失 | 第一版完成 streaming prefill，decode 作为扩展 |
| 板级功耗难测 | 实测数据不足 | 使用电源监控 + SAIF 估计双来源 |
| MHA 集成复杂 | 集成慢 | 先单 head 对拍，再按 head 循环调度 |
| GQA 来不及 | 创新点不足 | 第一版预留寄存器，答辩展示扩展仿真 |

## 18. 首版实现建议

第一版不要过早追求完整 Transformer 全流程，先确保竞赛硬要求闭环：

1. 实现 32x32 阵列。
2. 实现 32 lane softmax。
3. 实现大于 4 KB 的 streaming KV tile cache，第一版目标为 128 KB。
4. 实现 AXI slave 配置/输入和 AXI master 输出。
5. 跑通一个 32x32x64 的 Attention。
6. 扩展到可配置 `seq_len`，覆盖 32/64/144/576。
7. 跑 Re10K `seq=576, heads=9, head_dim=64`，得到真实网络数据。

后续优化优先级：

1. 在线 softmax + 不落地 S/P。
2. ping-pong 缓冲减少 stall。
3. streaming KV tile cache bank 并行和数据复用。
4. clock enable 与 bank enable 降低功耗。
5. GQA、多 batch、decode 模式扩展。
