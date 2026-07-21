# FlashAttention 加速器架构与实施计划

## 0. 文档定位

本文描述当前 RTL 已经实现的架构、明确的功能边界和后续开发路线，取代旧版
`plan.md` 中混杂的历史 OS-PV、外置 softmax、BF16-like 数据通路和建议性缓存
容量。文档状态日期为 2026-07-21。

设计事实按以下优先级维护：

1. `rtl/` 下可综合代码。
2. `docs/impl/` 下模块级接口与实现约束。
3. `docs/debug.md` 中的数据流优化、周期变化和遗留问题。
4. `docs/synth.md` 中的综合结果、关键路径和物理风险。
5. `fpga/docs/attention_test_plan.md` 中的上板测试流程。
6. 本文负责把当前实现与后续路线连接起来。

未出现在 RTL 中的功能必须标记为“计划”，不得写成已实现能力。

## 1. 当前产品定义

### 1.1 第一阶段基线

当前设计是面向 batch=1、MHA-compatible prefill 的 FlashAttention 加速器：

| 项目 | 当前实现 |
| --- | --- |
| FPGA 目标 | AMD/Xilinx VCK190，VC1902 |
| ASIC 工艺库 | `/data/public` 下 28 nm 标准单元和 SRAM 库 |
| 物理 PE 阵列 | 固定 32x32，划分为四个 8x32 stripe |
| tile | `Bq=32`，`Bk=32` |
| 默认 head dimension | 64 |
| Q/K/V | tile cache 中为 signed INT8 |
| QK 累加 | signed INT32 |
| probability | unsigned Q1.15，16 bit |
| 行状态 | signed 32-bit `m`，32-bit 定点 `l` |
| persistent O | signed INT32，按 row/feature 寻址 |
| 最终输出 | signed INT8 |
| 控制接口 | 32-bit AXI4-Lite slave |
| 输入数据 | 128-bit staged tile-loader 侧带接口 |
| 输出数据 | 128-bit AXI4 master burst write |
| 主数据流 | OS-QK + 阵列内 online softmax + probability-stationary WS-PV |

模型级序列按 32-token tile 流式处理，不常驻 PL tile cache。默认 cache 只保存
一个 head 的当前 tile 和下一 tile。

### 1.2 已实现能力

- head、Q tile、KV tile 三层 prefill 调度。
- 运行时配置 `seq_q`、`seq_kv` 和 head 数。
- 第一阶段固定 32x32 tile。
- causal mask 和不足 32 的尾 tile 屏蔽。
- Q 与 K/V 的 ping-pong 生命周期管理。
- PE 内 output-stationary QK 累加。
- 基于逐 PE 寄存链的 rowmax、反向 `m_new`、减法和 rowsum。
- 32-row 并行 scale/exp 流水，列启动间隔为 1 cycle。
- probability 回写并驻留在 PE 内。
- feature-major WS-PV 和 stripe-local persistent O-bank。
- WS-PV 与逐行 `l` 更新重叠。
- 8-row 最终归一化和 128-bit AXI 输出。
- ASIC 分层时钟门控以及兼容 FPGA CE/EN 的时钟策略。
- module/top TB 默认生成 FSDB。

### 1.3 尚未实现能力

- 原生 GQA head 映射和 K/V head 复用。
- autoregressive decode 调度与 32-row packing。
- 顶层内部用于读取 Q/K/V 的 AXI read master 或 DMA。
- 面向可停顿 tile loader 的完整 ready/credit 协议。
- 运行时任意切换 `HEAD_DIM`；当前硬件按 elaboration 参数生成，64 是已验证基线。
- 仅修改参数即可生成可布线的 128x128 物理阵列。
- 高利用率 ASIC SRAM 重组。
- FPGA/ASIC post-route 频率、功耗、IR-drop 和 hold signoff。

因此，SmolLM2 第一阶段测试需要在 PS 端把 3 个模型 KV heads 复制为 9 个
accelerator KV heads；原生 9Q/3KV GQA 属于第二阶段。

## 2. 算法与数值协议

### 2.1 分块在线 Attention

每个 Q tile 和 KV tile 执行：

```text
S[i,k]      = dot(Q[i,:], K[k,:])
block_m[i]  = max_k S[i,k]
m_new[i]    = max(m_old[i], block_m[i])
alpha[i]    = exp(m_old[i] - m_new[i])
P[i,k]      = exp(S[i,k] - m_new[i])
block_l[i]  = sum_k P[i,k]
l_new[i]    = alpha[i] * l_old[i] + block_l[i]
O_new[i,d]  = alpha[i] * O_old[i,d]
              + sum_k P[i,k] * V[k,d]
```

最后一个 KV tile 完成后：

```text
O_final[i,d] = requantize(O_new[i,d] / l_new[i])
```

首个 KV tile 使用 `m=-infinity`、`l=0` 和 zero O seed。完整 S/P 不写入片上
SRAM，也不写入外存。

### 2.2 当前定点格式

| 数据 | 格式/位宽 | 当前用途 |
| --- | --- | --- |
| cache Q/K/V | signed INT8 | 一个 256-bit word 包含 32 lanes |
| array Q/K/V 边界 | signed INT8 | 只在 PE 乘法器入口扩展 |
| QK score/delta | signed INT32 | PE-local `accum_q` |
| scale 后 score | signed Q8-style 16 bit | PWL exp 输入 |
| probability/alpha | unsigned Q1.15 | `[0,32767]` |
| row sum `l` | 32 bit | online recurrence |
| persistent O | signed INT32 | 每 row、每 feature 一个值 |
| 最终输出 | signed INT8 | rounding + saturation |

当前设计不存在 BF16 或通用浮点 softmax。`scale_requant_unit` 完成定点乘法、
移位、舍入和饱和；`pwl_exp_unit` 在非正 Q8 输入域使用 8 段线性近似，正输入
钳位为 1，`x<=-8` 钳位为 0。

### 2.3 舍入规则

scale 路径采用 shift-first guard/sticky，执行 round-to-nearest、ties-away-from-zero，
再做 INT8/INT16 saturation。该实现已删除旧的宽 rounding-bias carry chain，并
避免负数整除时被额外向负方向偏置。

## 3. 顶层架构

```text
                         32-bit AXI4-Lite
                                |
                       +--------v--------+
                       | register file   |
                       | scheduler/perf  |
                       +--------+--------+
                                |
128-bit tile loader            phase/control
        |                       |
+-------v-----------------------v--------------------------------+
|                  attention_accel_top                           |
|                                                               |
|  +--------------- Q/K/V ping-pong cache -------------------+  |
|  | Q0/Q1/K0/K1/V0/V1，逻辑深度为 HEAD_DIM，word=256 bit   |  |
|  +----------+------------------+----------------------------+  |
|             | Q/K              | feature-major V               |
|  +----------v------------------v----------------------------+  |
|  | QK/PV engines + fused 32x32 array                       |  |
|  | 4 x 8x32 stripes                                       |  |
|  | OS-QK -> rowmax -> reverse m/sub -> shared exp         |  |
|  | -> PE-local P -> rowsum -> WS-PV                      |  |
|  | stripe-local persistent O banks                         |  |
|  +--------------------------+------------------------------+  |
|                             | 8 rows x one feature             |
|                    +--------v---------+                        |
|                    | online normalizer|                        |
|                    | 8 reciprocal lanes                        |
|                    +--------+---------+                        |
|                             | 8 x INT8                          |
|                    +--------v---------+                        |
|                    | output buffer   |                        |
|                    | 256-bit words   |                        |
|                    +--------+---------+                        |
+-----------------------------|---------------------------------+
                              v
                    128-bit AXI4 master write
```

compute hierarchy 不允许完整 PE matrix state 跨模块传输。跨 stripe 使用固定
slice、常量邻接连接和寄存 tag，禁止运行时索引 `ROWS*COLS*WIDTH` 大总线。

## 4. 当前 tile 数据流

### 4.1 Job 级循环

```text
for head in Q heads:
    for q_tile in ceil(seq_q / 32):
        activate/commit Q tile
        initialize row state; first KV tile selects zero O seed
        for kv_tile in ceil(seq_kv / 32):
            activate/commit K/V tile pair
            run OS-QK
            run online-softmax column wave
            run probability-stationary WS-PV
        normalize final O tile
        AXI write O tile
```

所有 phase transition 都由 handshake 驱动，不假定 cache、array、normalizer 或
AXI 的固定延迟。

### 4.2 OS-QK

- array row `i` 对应一个 query token。
- array column `k` 对应一个 key token。
- Q 从左侧进入并按 row index skew。
- K 从上方进入并按 column index skew。
- 每个 PE 在 `HEAD_DIM` 个 feature cycles 内累加一个 signed INT32 `S[i,k]`。
- causal/tail 无效 lane 在 max 阶段贡献 score minimum，在 probability 阶段贡献 0。

QK 最后一个 token 沿寄存邻接通路传播，score 始终保留在 PE 内。

### 4.3 Rowmax 与反向 `m_new`

相邻列相差一个周期完成。列 `c` 收到 QK final token 时，把本列 score 与来自
列 `c-1` 的寄存 partial max 比较，因此 rowmax 与 QK tail 重叠，不再重新扫描
一遍 score row。

最右端计算：

```text
m_new = max(m_old, block_max)
alpha = exp(m_old - m_new)
```

随后 `m_new` 从右向左 restream。每个 PE 执行 `S-m_new` 并覆盖 `accum_q`，
score 和 delta 不占用两套寄存器。

### 4.4 Column-streamed Exp 与 Rowsum

每个完成的 delta column 由四个固定 8-row stripe slices 组成 32-row vector，进入：

```text
32 x score_scale_pipe -> 32 x pwl_exp_unit
```

组合流水 latency 为 8 cycles，列 initiation interval 为 1。column tag 与数据一起
返回，stripe 在本地译码为 32-bit one-hot，每个被选列只驱动本 stripe 的 8 个 PE。

probability writeback 形成连续列波。rowsum token 比所需 probability writeback
晚一个周期跟随该波，因此 SUB、exp、probability writeback 和 rowsum 相互重叠，
而不是四次串行扫描。

32 个 row sums 同时完成后暂存为 1024-bit bounded state。`old_l`、captured sums
和独立 alpha copy 作为三条 shift stream，从固定低位端口进入一个 latency=2、
II=1 的 unsigned `old_l*alpha` datapath；结果从固定高位写入 `l_rows` shift
register，每周期提交一行 `l_new`。行计数器只作为流水 tag，不再选择三条宽
packed vector，也不再译码 1024-bit 动态写使能。

### 4.5 Probability-Stationary WS-PV

当所有 `prob_q`、alpha 和 captured row sums 就绪时，阵列产生
`softmax_pv_ready`。该事件早于全部串行 `l` write 完成。

WS-PV 阶段：

- `P[i,k]` 驻留在 PE `(i,k)` 的 `prob_q`。
- V cache 地址 `d` 返回 feature-major `V[0:31,d]`。
- V 复用 K 的 vertical skew 和从上到下 PE links。
- feature tag `d` 与 horizontal partial sum 同步传播。
- 首个 KV tile 的左侧 seed 为 0。
- 后续 KV tile 的左侧 seed 为 stripe O-bank 读出的 `alpha[i]*O_old[i,d]`。
- PE 执行 `sum_out=sum_in+P[i,k]*V[k,d]`。
- right-edge 结果按 tag 直接写回 `O_new[i,d]`。

默认 64 features 是一次连续 issue stream。两个 32-feature O-memory groups 只是
物理 bank，不是两个 serial compute halves，也不存在 half-boundary array restart。

WS-PV 与中心 `l` updater 重叠。顶层 sticky guard 要求 PV 和 `l` update 都完成
后，才能进入下一 KV tile 或最终归一化。

### 4.6 最终归一化与输出

最后一个 KV tile 后，每周期读取一个 stripe 的同一 feature：

```text
8 x O[i,d] + 8 x l[i]
    -> 8 reciprocal/normalization lanes
    -> 8 signed INT8 outputs
```

output buffer 为每个 row 把 32 feature bytes 打包为一个 256-bit word。每个
stripe/group 依次写 8 个 row words，再进入下一 group 或 stripe。AXI reader 持有
当前 256-bit SRAM word，在 backpressure 下分别输出 lower/upper 128-bit，不重复
访问 SRAM。

默认 32x64 output tile：

```text
output bytes = 32 * 64 = 2048
AXI beats    = 2048 / 16 = 128
```

AXI burst 同时受配置长度、剩余 beats 和 4-KB boundary 限制。

## 5. Compute 微架构

### 5.1 Fused PE

当前 PE state：

- `accum_q`：先保存 QK score，再保存 `score-m_new`。
- `prob_q`：驻留 Q1.15 probability。
- Q 与 K/V forwarding registers。
- max、reverse-m 和 sum 的寄存邻接 links。
- QK/WS-PV phase 互斥共享的一处乘法表达式。

当前运算：

```text
QK:    signed Q * signed K -> signed INT32 accumulation
WS-PV: unsigned P * signed V -> signed INT32 horizontal sum
MAX:   max(local score, incoming partial max)
SUB:   local score - m_new
SUM:   incoming partial sum + local probability or P*V
```

invalid operand 被置零以降低 multiplier switching。

### 5.2 Stripe 划分

32x32 阵列由四个 8x32 `fsa_stripe` 构成：

- probability decode 和 phase control 保持 stripe-local。
- delta selector 先分成四个 8-column groups，再经过寄存二级 bounded mux。
- K/V 只在显式 stripe boundary 处跨区。
- 每个 stripe 拥有 8 个独立 persistent O row banks。
- 完整 O row、score/probability/accumulator matrix 均不跨 stripe。

增加逻辑 `HEAD_DIM` 只改变 cache depth 和 O-bank 数量，不增加物理 PE rows/cols。
超过 32 columns 必须增加 selector、clock/control 和 floorplan hierarchy；128x128
不是合法的直接参数化配置。

### 5.3 共享非 MAC 单元

| 单元 | 并行度 | 用途 |
| --- | ---: | --- |
| Score scale | 32 lanes | INT32 delta 转 signed Q8 |
| PWL exp | 32 lanes | Q8 非正输入转 Q1.15 |
| Row-state update | 1 row/cycle | `alpha*l_old+block_l` |
| O-old rescale | array flow 中 32 rows | 生成 `alpha*O_old` seed |
| Final normalizer | 8 rows/cycle | reciprocal、output scale、INT8 saturation |

32-lane score/exp 位于每个 KV tile 的循环内。8-lane final normalizer 只在最后
一个 KV tile 后执行，因此不会限制 recurrent softmax/PV throughput。

## 6. Memory 架构

### 6.1 `HEAD_DIM=64` 的逻辑容量

每个 cache word 为 32 个 INT8 lanes，即 256 bits；每个 ping-pong side 保存
64 个 feature words。

| Storage | 逻辑容量 |
| --- | ---: |
| Q active side | 64 x 256 bit = 2 KiB |
| Q next side | 2 KiB |
| K active + next | 4 KiB |
| V active + next | 4 KiB |
| Q/K/V staging 总计 | 12 KiB |
| Persistent O | 32 x 64 x 32 bit = 8 KiB |
| Normalized output | 32 x 64 x 8 bit = 2 KiB |

旧文档中每个 Q/K/V cache 64 KiB 的描述已经失效。当前 cache 精确保存一个 head
的 active/next tile，不保存多个模型 tile，也不保存 autoregressive history。

### 6.2 Q/K/V Layout

- Q/K cache 地址是 head-dimension feature index。
- 每个 word 返回 32 个 query/key lanes。
- V 以 transpose 后的 feature-major 形式加载：地址 `d` 返回 `V[0:31,d]`。
- loader 把两个有序 128-bit beats 组装为一个 256-bit word。
- 对应 bank commit 后 tile 才能被 compute 使用。
- Q 生命周期独立；K/V 作为一对同时 switch/consume。

inactive side 可以在 active side 计算时加载。DMA/loader 不得覆盖 active bank。

### 6.3 Persistent O Layout

每个 stripe row 拥有一个按 full feature ID 寻址的 32-bit bank：

```text
FEATURE_GROUPS = ceil(HEAD_DIM / ARRAY_COLS)
```

默认 D=64 有两个 groups。read/write 都携带 feature tag，因此 KV tile 之间不做
whole-row preload、shift 或 transpose。同一个 single-port group 的同周期读写非法，
仿真中有 assertion 检查。

### 6.4 Technology Mapping

| 目标 | Q/K/V | Persistent O | Normalized output |
| --- | --- | --- | --- |
| FPGA | wrapper attribute 推断 URAM/BRAM | BRAM | BRAM |
| ASIC | `/data/public` 256x8 single-port SRAM 组合 | row/group macro 组合 | 256-bit word 组合 |

当前 ASIC 映射使用 480 个 SRAM macros，物理容量 983040 bits，有效逻辑容量约
180224 bits，利用率约 18.3%。SRAM 重组推迟到第一版 FPGA baseline 之后。

### 6.5 Memory 功耗规则

- 只在真实 read/write 时 enable macro。
- write 只打开被选择的 byte banks。
- idle 时保持 address/data 稳定。
- single-port write collision 时禁止产生 read-valid。
- 两个 AXI beats 期间保持同一个 256-bit output word。
- 模型级 KV history 保存在 PS DDR/LPDDR，PL 只保留 tile cache。

## 7. Control 与外部接口

### 7.1 Scheduler FSM

```text
IDLE -> LOAD_Q -> LOAD_KV -> QK -> SOFTMAX -> PV
                                           |      |
                        next KV tile <------+      |
                                                  v
                                     final tile -> WRITEBACK
                                                    |
                                      next Q/head or DONE
```

fatal protocol/config/compute/AXI error 进入 sticky `ERROR`，直到软件 clear。第一
阶段只接受 prefill，拒绝 decode；tile size 不是 32x32 时拒绝启动。

`SOFTMAX->PV` 使用 `softmax_pv_ready`，而不是更晚的 row-state-done。下一 tile
仍必须等待 PV 与 `l` update 的组合完成条件。

### 7.2 Top-Level Interface

`attention_accel_top` 当前暴露：

1. AXI4-Lite slave，用于配置和状态。
2. 128-bit `tile_load_*`，携带 kind、bank、address、half、valid、ready。
3. Q/K/V tile commit 侧带接口。
4. 128-bit AXI4 master write channel。
5. IRQ 和 debug state。

RTL 顶层没有 AXI read master。VCK190 block design 必须在 PS DDR/NoC 和
`tile_load_*` 之间增加 AXI DMA 或 custom AXI-to-tile-loader wrapper。

### 7.3 Register Map

| Offset | Name | 当前用途 |
| --- | --- | --- |
| 0x00 | CONTROL | start/reset/clear、mode、causal、prefill/decode |
| 0x04 | STATUS | busy/done/error 和 active phase |
| 0x08 | ERROR_CODE | sticky error |
| 0x0C | VERSION | RTL version |
| 0x10-0x2C | Q/K/V/O base | 64-bit split；input base 预留给 DMA integration |
| 0x30-0x3C | Q/K/V/O stride | O stride 生效；input stride 预留给 loader/DMA |
| 0x40 | SEQ_Q | query length |
| 0x44 | SEQ_KV | key/value length |
| 0x48 | NUM_Q_HEADS | Stage-1 head loop |
| 0x4C | NUM_KV_HEADS | Stage 1 必须等于 Q heads |
| 0x50 | HEAD_DIM | 必须匹配 elaborated 支持值 |
| 0x54/0x58 | TILE_Q/TILE_K | Stage 1 固定 32/32 |
| 0x5C | MODE | MHA/GQA、prefill/decode、causal |
| 0x60 | SCORE_SCALE | exp 前 scale mantissa/shift encoding |
| 0x64 | VALUE_SCALE | value-scale 行为完成前为 reserved |
| 0x68 | OUT_SCALE | output mantissa/shift encoding |
| 0x6C | MASK_CFG | mask configuration |
| 0x70-0x8C | PERF | control、cycles、stalls、MACs、tiles |

配置采用 shadow register。START 成功时原子复制整次 run 的配置；busy 时拒绝普通
配置写入。

### 7.4 Clocking

- FPGA：`fa_clock_gate` 透传 root clock，valid-qualified register update 和 RAM/DSP
  enable 推断 CE/EN。若后续粗粒度停钟，只允许 `BUFGCE/BUFHCE`，禁止 LUT-gated
  clock。
- ASIC：wrapper 映射 `CKLNQD4BWP12T30P140`。当前 netlist 有 1 个 array-control/exp、
  4 个 stripe、1 个 normalizer、1 个 output-buffer ICG，共 7 个。

## 8. 参数化边界

### 8.1 运行时配置

- `seq_q/seq_kv` 为 16 bit，并按 32 分块。
- head 数用于第一阶段 MHA-compatible head loop。
- causal enable、scale、output address/stride 可运行时配置。
- tail rows/columns 使用 mask，不改变物理阵列大小。

### 8.2 Elaborate-Time 配置

- `ARRAY_ROWS=32`、`ARRAY_COLS=32` 必须与 `CACHE_WORD_W/8=32` 匹配。
- `ARRAY_ROWS` 必须能被 `STRIPE_ROWS=8` 整除。
- `HEAD_DIM` 决定 cache depth、feature tag width 和 O feature groups。
- `HEAD_DIM=128` 已通过 elaboration，但未完成完整数值和时序回归，暂不能列为已支持。

修改 array parameter 不代表能得到物理可行的大阵列。超过 32 columns 需要新的
selector、clock/control hierarchy 和 floorplan。

## 9. 验证基线

当前状态：

- 24 个普通 module/integration TB 全部通过。
- ASIC SRAM backend 专用测试通过。
- module TB 默认生成 FSDB。
- top TB 覆盖两个 KV tiles、online recurrence、final normalization、AXI
  writeback 以及 WS-PV/`l` update overlap。
- 当前 top TB 为 1354 cycles，原始 fused baseline 为 2174 cycles。Round-4 新增 14 cycles
  来自 score-scale 两级乘法流水和 stripe-local O-seed 寄存边界；两条路径均保持
  II=1。Round-5 再增加 6 cycles，来自每个 QK tile 的 local-clear 建立周期和每个
  PV tile 的两级 O-rescale startup；这些路径同样保持 II=1，因此长序列
  steady-state 吞吐不变。
- `HEAD_DIM=128` elaboration 通过。
- 已覆盖 4-KB AXI burst splitting 和 128-bit backpressure。

FPGA signoff 前必须补充：

- signed random V 和至少两个 KV tiles 的 nontrivial alpha。
- causal 与非 32 整数倍 sequence tails。
- 所有后续 narrowed datapath 的数值边界/overflow vectors。
- stallable loader 完成后的随机 loader delay/underrun。
- 如保留 D=128，补齐其 functional regression。
- FPGA post-synthesis/post-route gate-level smoke。
- representative prefill workload 的 SAIF。

## 10. 当前综合基线

Round-2 条件为 TT 0.9 V/25 C、2.5 ns、ideal clock、zero wire load：

| 指标 | Round-2 | 含义 |
| --- | ---: | --- |
| Setup WNS/TNS | +0.0067 ns / 0 | ideal TT 下勉强通过 400 MHz |
| Critical path | 约 2.38 ns，76 levels | normalizer scale multiplier |
| Hold WNS/TNS | -0.2939 / -1820.17 ns | SRAM min-delay 重复保守 |
| Cell area | 3144017.58 um2 | 不含 wire/halo |
| Fused-array area | 2760406.31 um2 | 总面积的 87.8% |
| Dynamic power | 8.5702 mW vectorless | 不是 signoff power |
| Clock internal power | 5.5262 mW | 报告 dynamic 的 64.5% |
| SRAM macros | 480 | 组织正确但利用率低 |

旧 rounding carry critical path 已消除。前 20 条 setup paths 都结束于旧版
normalizer scale multiplier。本轮 RTL 已改变乘法器位宽、completion 网络与 reset
结构，因此修改期间启动的频率扫描不能作为当前 RTL baseline；必须固定本轮源码
版本后重跑。可实现 ASIC 频率仍必须由 physical-aware SS 结果决定。

4350 条 max-fanout violation 的实际最大 fanout 只有 19，主要来自全局阈值 16，
不是新的千级负载网络。剩余 check-design finding 应分类处理，不能为清零报告盲删
接口。

## 11. 后续开发路线

### 11.1 Round 3：数据通路与时序

P0-A、P0-B、P0-C、P1-A 和 datapath reset 已完成 RTL/约束修改并通过现有仿真；
其面积、功耗和时序收益仍待固定版本的 TT/SS 综合确认。两级 II=1 multiplier
已经用于 normalizer 48x16 和 score-scale 32x16，stripe-local O-seed 寄存边界也已
切断 SRAM read 到 rescale 的单周期路径。SAIF 实际采样和 fanout 阈值扫描尚未执行。

#### P0-A：原生 8-bit Q/K/V Array Path

engine、array boundary、PE forwarding register 已恢复为 native signed INT8：

```text
QKV_W  = 8
PROB_W = 16
multiplier A = 17 bit：signed Q 或 zero-extended P
multiplier B = 9 bit： signed K/V
```

PE 共享乘法器已从近似 17x17 降为 17x9。QK 保留精确 16-bit product，PV 保留精确
24-bit product，再 sign-extend 到 32-bit accumulator。32-lane row/column bus 从
512 bit 降为 256 bit。该修改不改变 cycle schedule，是近期最大的 PE 面积、功耗
和 routing 优化点。另检查并删除了 old-O rescale 和 LSE 路径中先扩展再相乘造成的
意外宽乘法。

#### P0-B：Normalizer Critical Path

当前关键表达式近似为：

```text
(norm_product_q[63:0] >>> 15) * signed_scale[15:0]
```

range analysis 表明移位后幅值小于 2^46。RTL 已在 sign-extension 检查后把结果
缩为保守的 signed 48-bit operand，再做 48x16 multiply；现有边界和顶层回归通过。

若 TT slack 仍小于 0.20 ns 或 SS 2.5 ns 不通过，再加入固定 latency 的 two-stage
multiplier wrapper：ASIC 使用 pipelined DesignWare mapping，FPGA 推断等价 DSP
pipeline。该修改只增加 startup latency，不降低每周期 8-row output throughput。

#### P0-C：修正 SRAM Hold Constraint

当前默认 0.2 ns `set_min_delay` 与 macro 自带 0.1208 ns hold requirement、0.02 ns
uncertainty 叠加。当前约束已把默认 min-delay 恢复为 0，保留 Liberty hold、hold
uncertainty 和 `set_fix_hold`。最终修复在 CTS 后使用 fast-cell/fast-SRAM/min-RC
与 propagated clock 完成。

#### P1-A：Completion Sideband

原二维 PE `q_last/k_last/mac_last` 网络已删除。当前使用阵列外
`ROWS+COLS` 一维 completion shift register，以固定 row taps 启动 rowmax、末端 tap
产生 QK completion，约删除 3072 个 sideband registers 及其 hierarchy ports。

#### P1-B：真实功耗与 Reset

- SAIF workload、readback、annotation coverage、hierarchical power 和
  `report_clock_gating` 流程已写入 `asic/docs/saif_power_plan.md`，实际采样等待 UVM
  系统级 workload。
- 分别测 idle、Re10K prefill、SmolLM2 prefill。
- valid 保护的主要数据 payload 已取消 async reset；state、valid、tag、counter 和
  外部可见 state 保持 reset。
- 用 reset X-propagation 和 gate-level test 验收。

#### P2：Fanout 与报告清理

- 比较 `FA_MAX_FANOUT=16/24/32` 的 WNS、buffer、area、transition 和 congestion。
- 保留 32-bit AXI address，waive 有意不译码的高位。
- 在结构修改后 waiver constant first-column max seed、非负 probability MSB 和
  physical-edge unused output。
- 只有明确改变软件协议后才删除 reserved config output。

### 11.2 第一阶段 FPGA Bring-Up

第一版 FPGA 交付仍为 prefill：

1. 在 Vivado block design 中加入 AXI DMA/custom tile-loader wrapper。
2. 按 hierarchy 检查 BRAM/URAM/DSP inference。
3. 先以 150 MHz bring-up，建立 200 MHz baseline；250/300/312.5 MHz 只有
   post-route timing 通过后才能报告。
4. 每个频点记录 WNS/TNS、utilization、route congestion、high-fanout、power 和
   loader underrun。
5. 分别统计 `PS_NATIVE`、`PS_INT8_REF`、`PS_PL_KERNEL`、`PS_PL_E2E`。
6. ping-pong 生效的条件是 load-stall cycles 小于 5%。

| Workload | 第一阶段配置 | 目的 |
| --- | --- | --- |
| Tile smoke | 32x32x64 | loader/array/writeback bring-up |
| Re10K | seq=8192，hidden=576，9 heads，D=64 | 必测真实 attention layer |
| SmolLM2-135M | prefill，PS expansion 后 9Q/9KV，D=64 | 第一版真实 LLM 对比 |

### 11.3 第二阶段：Native GQA 与 Decode

第二阶段保持 PE arithmetic 和 online-softmax recurrence，只替换 head mapping、
row ownership 和 tile lifetime。

Native GQA：

- `kv_head_id=q_head_id/group_size`。
- 一个 native KV-head tile 只加载一次，供映射到它的多个 Q heads 使用。
- 增加 per-bank reference count，最后一个 Q head 完成后才释放 KV bank。
- `m/l/persistent O` 保持 Q-head-specific。
- 实测相对 PS-side MHA expansion 的 K/V traffic reduction。

Decode：

- model-level KV history 保持在 PS DDR/LPDDR。
- append 新 token 后，把历史 KV 按 32-token tiles 流入现有 PL ping-pong cache。
- `seq_q=1` 时把独立 Q heads、batch 或 beams pack 到 32 rows。
- 每个 physical row 携带 `{batch,beam,q_head,kv_head,token}` metadata。
- 增加 context-length-driven DMA queue 和显式 loader underrun/credit handling。

实施顺序：

1. Head mapping 与 GQA KV-bank reference count。
2. Q-head state address 与 physical row 解耦。
3. Decode row descriptor 和 mask generation。
4. Historical KV tile loop 与 DMA queue。
5. Batch/beam packing 和性能计数器。
6. context 128/512/1024/2048 回归。

SmolLM2-135M 的 native 9Q/3KV GQA 目标是相对 MHA expansion 接近 3x 降低 K/V
tile traffic，alignment/descriptor overhead 单独统计。只有数值匹配且 end-to-end
traffic reduction 实测成立后才验收。

### 11.4 后续 ASIC 工作

- 按更合适的 aspect ratio 重组浅逻辑 memory，优先处理低利用率 persistent O。
- 构建同时包含 standard-cell FRAM 和 SRAM abstract 的 physical library。
- 运行 physical-aware TT/SS synthesis，把 stripe 与对应 O-bank 放在邻近区域。
- Q/K/V macros 靠近 issue boundary 放置。
- 完成 CTS、fast/min-RC hold、DFT/scan、LEC、SAIF power、IR-drop、EM、DRC/LVS。

## 12. 性能模型与采样

### 12.1 运算量

单 head：

```text
QK MACs = seq_q * seq_kv * head_dim
PV MACs = seq_q * seq_kv * head_dim
Total   = 2 * seq_q * seq_kv * head_dim
```

物理峰值为 1024 MAC/cycle，但 utilization 必须用实际 valid MACs 和实测总周期，
包括 wavefront fill/drain、softmax 和 PV phase。

### 12.2 当前周期基线

两 KV tile top test：

| 版本 | Cycles | 累计节省 |
| --- | ---: | ---: |
| Original fused baseline | 2174 | - |
| Probability-stationary WS-PV | 1794 | 17.5% |
| Continuous feature/softmax stream | 1581 | 27.3% |
| Column-overlapped SUB/exp/rowsum | 1519 | 30.1% |
| WS-PV overlapped with `l` update | 1453 | 33.2% |
| Persistent O + 8-lane normalization | 1334 | 38.6% |
| Round-4 timing pipeline boundaries | 1348 | 38.0% |
| Round-5 local-clear and O-rescale pipelines | 1354 | 37.7% |

该数字是 regression baseline，不是完整模型吞吐。

### 12.3 带宽

一个 INT8 KV tile/head：

```text
K bytes = 32 * HEAD_DIM
V bytes = 32 * HEAD_DIM
KV bytes/tile = 2 * 32 * HEAD_DIM
```

`HEAD_DIM=64` 时为 4096 bytes。只有 inactive-side load time 不超过 current-tile
compute time，ping-pong 才真正隐藏传输。

必须采样：

- PL cycles 和实际 clock。
- DMA submit/complete time。
- loader stall/underrun。
- AXI write stalls/bytes。
- valid MAC 与 array-active cycles。
- DDR bytes/tile/token。
- idle/active board power。
- fixed-point 与 FP reference 数值误差。

## 13. 验收标准

### 13.1 Stage-1 RTL

- module/top TB 全部通过且无 protocol error。
- 输出匹配 bit-accurate reference。
- 覆盖 tail、causal、first/non-first KV tile 和 AXI backpressure。
- major compute boundary 不出现完整 S/P 或 PE-state bus。
- Round-3 width change 通过边界和等价性测试。

### 13.2 FPGA Prefill

- Vivado post-route timing 在报告的 production clock 下通过。
- Q/K/V 和 O-bank 推断预期 BRAM/URAM，PE multiply 推断预期 DSP。
- Re10K seq=8192 和 SmolLM2 prefill 无 loader underrun。
- kernel-only 与 PS+PL end-to-end 分开报告。
- 输出误差满足约定 INT8 threshold。

### 13.3 ASIC Readiness

- TT/SS logical synthesis、narrowed frequency scan 和 physical-aware synthesis 完成。
- normalizer/PE path 具有实现裕量，而不是 TT zero slack。
- 真实 SAIF 替代 vectorless power。
- fast/min-RC hold 可在 CTS 后修复。
- SRAM aspect ratio、floorplan、clock/reset 和 scan strategy 在 P&R 前冻结。

## 14. 架构不变量

后续修改必须保持以下原则，除非重新审核架构：

1. S/P 不写外存，也不写中央 tile SRAM。
2. score、subtract、probability 和 reduction 保持 PE-row local；exp 是唯一位于 PE
   外部的共享 score/probability arithmetic pipeline。
3. WS-PV 保持 probability stationary，feature-major V 连续覆盖全部 64 features。
4. persistent O 按 feature 寻址，禁止 whole-row preload/shift。
5. 跨 stripe data 必须寄存且位宽有界。
6. major block 之间禁止 `ROWS*COLS*WIDTH` state port。
7. FPGA clock 使用 dedicated resource 或 CE/EN；ASIC 使用已验证 ICG。
8. Stage 2 model-level KV history 在外存，PL memory 仍为 tile cache。
9. 参数化不能绕过物理 routing limit。
10. 性能结论必须包含 data movement 和实测 clock。

## 15. 模块职责

| 模块 | 职责 |
| --- | --- |
| `attention_accel_top.v` | 集成、normalization traversal、writeback address |
| `accel_regfile.v` | AXI-Lite 软件协议和 shadow config |
| `accel_scheduler.v` | head/Q/KV loops 和 phase FSM |
| `fsa_controller.v` | QK/PV array phase handshake |
| `fsa_qk_engine.v` | cache-to-array Q/K issue |
| `fsa_pv_engine.v` | feature-major V issue 和 feature tag |
| `fsa_fused_array.v` | row state、exp orchestration、WS-PV、normalizer read port |
| `fsa_stripe.v` | 8x32 local routing、delta selector、persistent O ownership |
| `fsa_fused_pe.v` | score/probability state 和 nearest-neighbor arithmetic |
| `scale_requant_unit.v` | fixed-point scale/round/saturate |
| `score_scale_pipe.v` | dedicated score scale/round/saturate, latency 5 |
| `pwl_exp_unit.v` | Q8-to-Q1.15 PWL exp |
| `reciprocal_lut.v` | pipelined reciprocal approximation |
| `online_normalizer.v` | 8-row O/l normalization 和 INT8 output |
| `qkv_tile_cache.v` | Q/K/V ping-pong storage 和 loader assembly |
| `o_accumulator_bank.v` | persistent feature-addressed O |
| `output_buffer.v` | output packing、SRAM staging、AXI stream source |
| `axi4_master_write.v` | aligned、4-KB-safe burst writeback |
| `fa_clock_gate.v` | backend-specific clock-gating policy |

## 16. 文档维护规则

- 本文只维护架构、已支持功能、milestone 和 acceptance criteria。
- signal-level behavior 写入 `docs/impl/`。
- RTL risk 和 cycle change 写入 `docs/debug.md`。
- 每轮 synthesis、critical path、area/power 和 physical issue 写入
  `docs/synth.md`。
- FPGA workload 和采样流程写入 `fpga/docs/attention_test_plan.md`。
- 历史替代方案保留在 git history，不再混入 active plan。
