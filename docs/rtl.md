# FlashAttention Accelerator RTL Code Guide

## 1. Document Purpose

本文从 `rtl/attention_accel_top.v` 开始，按照一次 Attention prefill
任务的真实计算顺序解释当前 RTL。阅读完成后，应能够回答以下问题：

1. 软件配置如何被锁存，任务如何遍历 head、Q tile 和 KV tile。
2. Q、K、V 如何进入 ping-pong cache，以及 256-bit cache word 的布局。
3. 32x32 PE 阵列如何先执行 output-stationary QK，再在 PE 内完成
   rowmax、`Score-m_new` 和 rowsum。
4. 为什么 exp 位于 PE 外部，但 Score 和 probability 不需要离开阵列存储。
5. probability-stationary WS-PV 如何复用同一阵列并原位更新持久化 O-bank。
6. 在线 softmax 的 `(m,l,O)` 如何跨 KV tile 递推，最终如何归一化和写回。
7. 每个 valid、tag、状态寄存器和流水边界为何存在。

本文只描述当前代码已经实现的行为。decode、GQA、AXI 读 DMA 等预留接口会在
“当前实现边界”中明确标出，不把计划功能当成现有功能。

## 2. Default Configuration and Numeric Formats

全局常量位于 `rtl/common/attention_defines.vh` 和
`rtl/common/fixed_defs.vh`。

| Item | Default | RTL meaning |
| --- | ---: | --- |
| `ARRAY_ROWS` | 32 | 一个 Q tile 的物理 query rows |
| `ARRAY_COLS` | 32 | 一个 KV tile 的物理 key/value rows |
| `STRIPE_ROWS` | 8 | 每个物理 stripe 包含 8x32 PEs |
| `HEAD_DIM` | 64 | 按时间流入阵列的 feature 数，不改变阵列尺寸 |
| `DATA_W` | 8 | Q/K/V 原生 signed INT8 通路 |
| `SCORE_W` / `ACC_W` | 32 | QK Score、O partial sum 和内部累加宽度 |
| `PROB_W` | 16 | unsigned Q1.15 probability/alpha |
| `LSE_W` | 32 | Q1.15 rowsum 状态 `l` 的扩展存储宽度 |
| `OUT_W` | 8 | 最终 signed INT8 output |
| AXI data width | 128 | 输出写回每 beat 16 bytes |
| Cache word | 256 | 32 个 INT8 Q/K/V elements |

主要定点关系如下：

```text
Score          = sum_d signed_Q8 * signed_K8                -> signed 32 bit
scaled_delta   = round((Score - m_new) * score_mant >> shift) -> signed 16 bit Q8
P              = PWL_exp(scaled_delta)                     -> unsigned Q1.15
l_new          = (l_old * alpha >> 15) + sum(P)            -> unsigned 32 bit
O_new[row,d]   = (alpha * O_old[row,d] >> 15)
                 + sum_k(P[row,k] * signed_V[k,d])          -> signed 32 bit
output         = sat_int8(round((O_new / l_new) * out_scale))
```

`score_scale_i` 和 `out_scale_i` 的低 16 位是 signed mantissa，位
`[21:16]` 是 6-bit right shift。当前 `value_scale` 配置尚未进入有效计算路径。

## 3. Active Module Hierarchy

```text
attention_accel_top
|-- accel_regfile
|   `-- axi4_slave_if
|-- accel_scheduler
|-- qkv_tile_cache
|   |-- pingpong_buffer x3
|   `-- banked_sram x6
|       `-- asic_sram_256xwide (ASIC) / inferred URAM (FPGA)
|-- fsa_controller
|-- fsa_qk_engine
|-- fsa_pv_engine
|-- fsa_fused_array
|   |-- fa_clock_gate
|   |-- fsa_delay_line: Q skew, V skew, O-seed row skew
|   |-- score_scale_pipe x32
|   |   `-- fa_signed_mult_pipe2
|   |-- pwl_exp_unit x32
|   |-- fa_unsigned_mult_pipe2: serialized l update
|   `-- fsa_stripe x4
|       |-- fa_clear_replica x4
|       |-- fsa_fused_pe x256
|       |-- fa_signed_mult_pipe2 x8: alpha*O_old
|       `-- o_accumulator_bank
|           `-- asic_sram_256xwide / inferred BRAM
|-- online_normalizer
|   |-- reciprocal_lut x8
|   `-- fa_signed_mult_pipe2 x8
|-- output_buffer
|   `-- asic_sram_256xwide / inferred BRAM
|-- axi4_master_write
`-- perf_counter
```

四个 stripe 合计 1024 PEs。Score、probability 和行规约数据只沿 PE 邻接链
移动，顶层没有 32x32 Score/Probability 超宽接口。

## 4. End-to-End Execution Flow

一次任务的外层循环由 `accel_scheduler` 实现：

```text
for head in num_q_heads:
  for q_tile in ceil(seq_q / 32):
    load Q tile
    clear online state (m,l,P validity) for this Q tile
    for kv_tile in ceil(seq_kv / 32):
      load K/V tile
      QK
      online softmax update
      WS-PV and persistent O update
    normalize final O with l
    write valid Q rows to memory
```

对应 scheduler 状态为：

| State | Enable | Completion condition | Next state |
| --- | --- | --- | --- |
| `IDLE` | none | legal `START` | `LOAD_Q` |
| `LOAD_Q` | `load_q_en_o` | active Q bank valid | `LOAD_KV` |
| `LOAD_KV` | `load_kv_en_o` | active K/V pair valid | `QK` |
| `QK` | `qk_en_o` | registered systolic tail | `SOFTMAX` |
| `SOFTMAX` | `softmax_en_o` | probability and rowsum ready | `PV` |
| `PV` | `pv_en_o` | WS-PV and l update both complete | next KV or `WRITEBACK` |
| `WRITEBACK` | `wb_en_o` | AXI B response for all data | next Q/head or `DONE` |
| `DONE` | idle status | clear or new legal start | `IDLE`/`LOAD_Q` |
| `ERROR` | none | software clear | `IDLE` |

状态转换全部由 handshake 驱动，不假定 cache、array 或 AXI 有固定总延迟。

## 5. Top-Level Integration: `attention_accel_top`

### 5.1 Four external interface groups

1. AXI4-Lite slave：软件配置和状态读取。
2. `tile_load_*`/`tile_commit_*`：外部 loader 向 Q/K/V cache 写入数据。
3. AXI4 write master：输出写回。
4. `irq_o` 和 `debug_state_o`：任务完成/错误中断和 scheduler 状态。

当前顶层没有 AXI read master。Q/K/V 的 base address 和 stride 能被软件配置，
但当前 RTL 不使用它们发起 DDR 读取；系统集成逻辑必须通过 `tile_load_*` 将数据
送入 cache。

### 5.2 Level-to-pulse conversion

Scheduler 对每个阶段输出 level enable。顶层用延迟寄存器生成单周期启动脉冲：

```text
qk_request     = qk_en     && !qk_en_d
softmax_start = softmax_en && !softmax_en_d
axi_start     = wb_en      && !wb_en_d
```

这防止阶段持续多个周期时重复启动子模块。PV 使用独立 `pv_flow_state_q`，因为
WS-PV、串行 l 更新和最终 normalization 之间存在重叠关系。

### 5.3 Q and KV lifetime

Q tile 在所有 KV tiles 期间保持有效，直到本 Q tile 写回完成才
`q_consume_w`。K/V 在一次 PV 完成后一起 consume。若另一 bank 已经 commit，
`q_switch_w` 或 `kv_switch_w` 会切换 active bank，从而允许 loader 与 compute
ping-pong 重叠。

### 5.4 Top-level PV/normalization FSM

`pv_flow_state_q` 处理 scheduler 的 `PV` 阶段：

| State | Purpose |
| --- | --- |
| `PV_FLOW_IDLE` | 等待 `pv_en` 上升沿 |
| `PV_FLOW_REQ` | 向共享阵列控制器发送 PV request |
| `PV_FLOW_WAIT` | 等待 PV engine 输出最后一个 feature |
| `PV_FLOW_WAIT_L` | PV 已结束，但串行 `l_new` 尚未结束 |
| `PV_FLOW_NORM_ISSUE` | 最后 KV tile 后逐 stripe/feature 读取 O 和 l |
| `PV_FLOW_NORM_DRAIN` | 每 32 features 等待 output buffer flush 8 rows |
| `PV_FLOW_COMPLETE` | 产生单周期 `pv_complete_q` |

`softmax_pv_ready_o` 在 rowsum 完成时产生，因此 scheduler 可以启动 WS-PV；
与此同时 `SM_L_UPDATE` 继续逐行更新 `l`。只有两者都完成，KV tile 才释放。

### 5.5 Writeback address maintenance

顶层不在每个 tile 边界重新计算大乘法，而是维护：

```text
head_base_addr
writeback_addr
head_stride_bytes = seq_q * o_stride
```

普通 Q tile 写回后地址增加 `32*o_stride`；最后一个 Q tile 后进入下一 head。
尾部 Q tile 的有效 row 数由 `seq_q-q_tile_base` 限制，写回字节数为
`valid_rows*HEAD_DIM*(OUT_W/8)`。

## 6. Control Plane

### 6.1 `axi4_slave_if`

AXI AW 和 W 可以独立到达，各有一个 holding register。两者都到达时才产生
`wr_fire_o`。AR 使用一个单 entry holding register，产生 `rd_fire_o`。
`wr_block_i`/`rd_block_i` 在上一次 B/R response 未被接受时施加 backpressure，
因此不会覆盖未完成事务。

### 6.2 `accel_regfile`

配置采用 shadow/snapshot 结构：

- `prog_*`：软件可写 shadow registers。
- `cfg_*`：成功 START 时原子复制的运行时快照。

因此任务运行时软件修改 shadow 不会改变当前任务。运行期间只有 CONTROL 和
PERF_CTRL 可写，其余写操作返回 `SLVERR` 并记录 sticky error。

START 当前要求：

- `seq_q`, `seq_kv`, head counts 非零；
- `HEAD_DIM=64`, `TILE_Q=TILE_K=32`；
- prefill=1、decode=0、MHA mode；
- `num_q_heads == num_kv_heads`；
- Q/K/V/O base 16-byte aligned。

也就是说 decode 和 GQA 位虽已存在于寄存器表，当前 START validation 会拒绝它们。

### 6.3 `accel_scheduler`

Scheduler 保存 `head_index`, `q_tile_index`, `kv_tile_index`。tile base 通过
左移 5 位生成：`tile_index*32`。KV index 在每次非末 tile PV 后递增；写回后
KV index 清零，再推进 Q tile 或 head。

## 7. Tile Cache and Memory Organization

### 7.1 Loader protocol

`qkv_tile_cache` 将两个 128-bit loader beats 拼成一个 256-bit word：

```text
half=0: latch pending_data[127:0], kind, bank, address
half=1: verify metadata, write {second_half, first_half}
```

第二 half 的 kind/bank/address 不匹配会置 `protocol_error_o`。完整 tile 写完后，
外部逻辑必须使用 `tile_commit_*` 标记对应 bank 有效。

### 7.2 Cache layout

每个地址对应一个 feature：

```text
Q cache[address=d] = Q[row=0..31, d]
K cache[address=d] = K[key=0..31, d]
V cache[address=d] = V[key=0..31, feature=d]
```

因此一个 256-bit word 恰好匹配 32 个阵列 rows/columns。Q、K、V 各有 ping/pong
两份，共六个 `banked_sram`。

### 7.3 `pingpong_buffer`

每个实例维护 `active_bank` 和两位 `bank_valid`。commit 已有效 bank、切换到空 bank
都会报告 protocol error。Q 独立管理；K/V 分别实例化 ownership 状态，但顶层要求
两者 active bank 一致且同时有效。

### 7.4 `banked_sram`

一个 256-bit cache word 被拆成 16 个 16-bit banks。输入 write/read request 先
寄存，以隔离宽总线和 SRAM macro。物理 memory 是 single-port：任何 bank 写入时
抑制共享 read。部分写入只 enable 被选中的 banks，其他 macros 保持关闭以降低功耗。

ASIC 使用 `asic_sram_256xwide` 或深度拼接的 `asic_sram_1024x16`；FPGA 使用
`ram_style="ultra"` 的二维 memory inference。

## 8. QK Issue: `fsa_qk_engine`

### 8.1 Shared-array arbitration: `fsa_controller`

QK 和 PV 复用同一 PE array。`fsa_controller` 在 IDLE 只接受一种 start request，
生成单周期 `qk_go_o` 或 `pv_go_o`，并将 `phase_o` 保持到对应 engine done。两个
request 同时出现、或 active engine 报错都会置 `error_o`。当前 `phase_o` 主要用于
状态可见性；fused array 的实际 QK/PV 数据选择由本地 `mac_phase_pv_q` 在
`qk_clear_i`/`pv_start_i` 边界更新。

### 8.2 QK engine sequence

QK engine 状态为：

```text
IDLE -> CLEAR -> CLEAR_LOCAL -> ISSUE -> DRAIN -> DONE
```

两个 clear 周期的用途不同：第一个周期把全局 clear 捕获到 stripe 内四个本地
replica；第二个周期保证所有 PE `accum_q` 都观察到 clear。随后 Q/K cache 地址
从 0 递增到 `head_dim-1`。request counter 与 response counter 分离，以容纳同步
cache latency。

每个有效 response 周期输出：

- `array_rows_o`: 32 个 signed INT8 Q elements；
- `array_cols_o`: 32 个 signed INT8 K elements；
- `array_last_o`: 当前 response 是最后一个 head feature。

Q/K valid 必须同时出现，否则 engine 报错。请求结束后进入 DRAIN，直到 fused array
返回注册后的 systolic tail。

## 9. Fused Array Entry and Systolic Skew

`fsa_fused_array` 是计算核心。它包含四个 8x32 stripe，并在阵列外生成规则 skew：

- Q row `r` 延迟 `r+1` cycles 后从左侧进入；
- K/V column `c` 延迟 `c+1` cycles 后从顶部进入；
- WS-PV 的 O seed row `r` 也延迟 `r+1` cycles 后从左侧进入。

这样 PE `(r,c)` 在同一周期看到匹配的数据。Q 水平传播、K/V 垂直传播，每经过一个
PE 都注册一次。`fsa_delay_line` 只在 valid 时更新 payload，bubble 时保持数据，减少
无效翻转；valid 和 last 始终逐级传播。

原来每个 PE 的 q_last/k_last/mac_last sideband 已被单个
`qk_completion_q[ROWS+COLS-1:0]` 替代。tap `row+1` 启动对应 row 的 rowmax，
最后 tap 产生 `qk_last_o`。

## 10. PE Microarchitecture: `fsa_fused_pe`

### 10.1 PE-local state

每个 PE 只有两个主要状态寄存器：

| Register | Width | Phase use |
| --- | ---: | --- |
| `accum_q` | 32 signed | QK Score；随后覆盖为 `Score-m_new` |
| `prob_q` | 16 unsigned | exp 输出 P；WS-PV 时保持 stationary |

共享 `accum_q` 避免同时保留 Score 和 PV accumulator。WS-PV partial sum 沿
`sum_data` 水平流动，不写入 `accum_q`。

### 10.2 Shared 17x9 multiplier

Q/K/V 在阵列连线和寄存器中保持 8 bit。只在乘法器入口扩展：

```text
QK: A = sign_extend(Q, 17), B = sign_extend(K, 9)
PV: A = {0, probability[15:0]}, B = sign_extend(V, 9)
```

QK 和 PV valid token 互斥，因此一个 PE 只需要一个 17x9 signed multiplier。
QK 使用低 16-bit exact product；PV 使用 24-bit exact product。显式 result context
避免 Verilog 按 operand width 截断乘法结果。

### 10.3 PE operations by phase

1. QK：`accum_q += Q*K`。
2. Rowmax：左侧 token 携带当前 max，每个 PE 比较本地有效 Score 后向右传递。
3. Reverse max：`m_new` 从右向左传播；PE 将 `accum_q` 覆盖成
   `lane_valid ? Score-m_new : SCORE_MIN`。
4. Probability load：stripe 将 column tag 解码成 one-hot，仅对应列写 `prob_q`。
5. Rowsum：右侧 zero token 向左移动，每个 PE执行 `sum+prob_q`。
6. WS-PV：左侧 partial sum 向右移动，每个 PE执行 `sum+prob_q*V` 并保留 feature tag。

Payload registers 在 valid=0 时不更新且不做异步复位；valid/control registers 负责
保证无效 payload 不会被消费。这既降低 reset tree 负载，也减少空闲翻转。

## 11. PE-Local Rowmax, Delta and Rowsum

### 11.1 Rowmax

最后一次 QK MAC 的完成 token 在每一 row 的 column 0 启动 max chain。初值是
32-bit 最小负数。masked lane 的 `max_score_w` 同样为最小负数，因此 padding/causal
元素不会影响结果。经过 32 columns 后，每行 block maximum 从右边界输出并锁存到
`block_max_rows_q`。

### 11.2 Padding and causal mask

`fsa_fused_array` 在 QK clear 时预计算 `lane_valid_q[32][32]`：

- 超过 `seq_kv` 的 columns 无效；
- 尾部 Q tile 超过 `seq_q` 的 rows 全无效；
- causal mode 只保留 `k_index <= q_index`。

PE 运行时只读取一个 local mask bit，不承担地址比较和大型广播逻辑。

### 11.3 Reverse `m_new` wave and delta collection

在线递推先计算：

```text
m_pending[row] = max(m_rows[row], block_max[row])
alpha_delta[row] = m_rows[row] - m_pending[row]
```

`SM_ALPHA_WAIT` 将 `m_pending_q` 提交到已注册的 `m_rows_q`，下一状态
`SM_M_START` 才把它送入 stripe 右边界。使用 `m_rows_q` 是重要时序边界，避免
block-max 组合选择直接串到 1024 个 PE subtractors。

每个 column 的 8-row delta 在 stripe 内先按 8 columns 分成四组选择并寄存，第二级
再选择一个 group。四个 stripe 必须输出相同 column tag，顶层才拼成 32-row column。
这避免单级 32:1 宽 mux，也避免传出完整 32x32 Score tile。

### 11.4 Column-parallel exp and overlapped rowsum

反向 `m_new` wave 使同一 column 的 32 rows 同时完成 `Score-m_new`。因此 exp
使用 32 lanes，每周期处理一个完整 column，而不是一行 32 elements。

```text
delta column
  -> score_scale_pipe x32, latency 5, II=1
  -> pwl_exp_unit x32, latency 3, II=1
  -> delayed column tag
  -> one-hot load into that PE column's prob_q
```

总 tag/data latency 是参数 `EXP_LATENCY=8`。column 31 的 probability 返回时，
rowsum zero token 立即从右边界启动；后续 probability columns 继续返回，而 rowsum
token 同时向左移动。因此 delta、exp、probability load 和 rowsum 形成重叠流水，
不是三个串行阶段。column 0 probability 返回后 FSM 已进入 `SM_SUM_WAIT`，只等待
最左侧 rowsum result。

## 12. Score Scaling and Exponential Approximation

### 12.1 `score_scale_pipe`

专用 score path 固定了 zero point、round 和 saturation policy，避免 32 份通用
requantizer 的无用控制网。它接受一个 input/cycle，延迟 5 cycles：

1. 捕获 Score、mantissa、shift。
2. `fa_signed_mult_pipe2` 用两个 partial products 实现两级精确乘法。
3. arithmetic shift，计算 guard/sticky，并缩到 18-bit formatting range。
4. round-to-nearest。
5. 饱和为 signed 16 bit。

### 12.2 `pwl_exp_unit`

输入是非正 signed Q8 delta，输出 unsigned Q1.15：

- `x>=0`：输出 32767；
- `x<=-2048`：输出 0；
- 中间范围按 `magnitude[11:8]` 选择 8 个 PWL segments；
- `magnitude[7:0]` 在两个 endpoint 之间线性插值。

关键流水边界位于 `endpoint_delta = base_lo-base_hi` 之后、16x8 乘法之前。
因此 decode/table/subtract 不与乘法处于同一组合周期。总 latency 为 3，II=1。

## 13. Online Softmax State Machine

`fsa_fused_array` 的 softmax FSM 为：

| State | Action |
| --- | --- |
| `SM_IDLE` | 捕获 `old_l` 和旧 row-valid |
| `SM_MAX_WAIT` | 等待所有 block rowmax |
| `SM_ALPHA_LAUNCH` | 将 `m_old-m_new` 送入 32-lane scale/exp |
| `SM_ALPHA_WAIT` | 捕获 alpha，提交 `m_new` |
| `SM_M_START` | 从右边界启动 `m_new` reverse wave |
| `SM_M_STREAM` | delta/exp/probability/rowsum 重叠 |
| `SM_SUM_WAIT` | 等待每行 `sum(P)` 到左边界 |
| `SM_L_UPDATE` | 每周期发射一行 `l_old*alpha` |
| `SM_L_DRAIN` | 等待最后两级乘法流水排空 |
| `SM_DONE` | 更新 row-valid 并产生 done pulse |

第一次 KV tile 时 row state invalid：`alpha=0`，但 P 仍由当前 block Score 计算。
后续 tile 才使用 `alpha=exp(m_old-m_new)` 缩放旧 `l` 和旧 O。

### 13.1 Serialized l update without wide dynamic mux

rowsum 完成后，`old_l_q`、`sum_rows_q` 和私有 `alpha_update_stream_q` 都作为
shift streams 使用。每周期固定读取最低 slice：

```text
product = old_l[0] * alpha[0]       // unsigned 32x16, latency 2, II=1
l_new   = saturate((product >> 15) + sum_rows[0])
```

三个输入流每周期右移一行，result 从 `l_rows_q` 固定高端写入。经过 32 次 commit
后 row 顺序恢复正确。该结构没有运行时 32:1 read mux 和 1024-bit dynamic write
decoder。`alpha_rows_q` 本体保留给并行启动的 WS-PV，512-bit 私有 stream 是为消除
大 mux 支付的存储成本。

## 14. WS-PV: `fsa_pv_engine` and Array Reuse

### 14.1 Feature-major V issue

PV engine 先产生 `array_start_o`，等待 fused array 切到 PV phase 并返回 ready，
然后地址 0..63 连续读取 V cache。每个 response 包含：

```text
V[:,d] = 32 signed INT8 values
feature tag = d
```

所以 64 维一次连续加载，II=1，不拆成两个 feature halves。

### 14.2 Align O seed with V

对于非首 KV tile，`pv_valid_i` 同周期使用 `d` 读取所有 stripe 的
`O_old[:,d]`。每个 stripe 捕获同步 SRAM output、对应 8-row alpha 和 feature tag，
使用 8 个 latency-2 `fa_signed_mult_pipe2` 计算：

```text
seed[row,d] = alpha[row] * O_old[row,d] >> 15
```

首 KV tile 的 `pv_seed_zero_i=1`，绕过未初始化 O memory，以 zero seed 开始。
V 数据经过 `pv_issue_cols_q -> pv_rescale_cols_q -> s1 -> s2` 延迟，与 O-rescale
输出严格对齐。之后 O seed 做 row skew，V 做 column skew。

### 14.3 Probability-stationary horizontal accumulation

每个 PE 已保存 `prob_q=P[row,k]`。V[k,d] 从顶部向下广播，partial sum 从左向右：

```text
PE[row,k]: sum_out = sum_in + P[row,k] * V[k,d]
```

feature tag 与 partial sum 一起传递。右边界得到 32 个
`O_new[row,d]`，每行根据自己的 tag 直接写回 stripe-local O-bank。不同 row 的
到达 skew 不需要全局重排，因为每个 write 都携带完整 feature 地址。

最后 row、最后 feature 的 tagged right-edge token 产生 `pv_done_o`。PV engine 在
`DRAIN` 等待该 token，而不是按固定周期猜测完成时间。

## 15. Persistent O-bank

`o_accumulator_bank` 的逻辑地址是 `[row][feature]`。默认 64 features 按
`GROUP_SIZE=32` 拆成两个物理 groups；groups 是并行存储组织，不是两个串行计算 half。

ASIC 组织为：

```text
4 stripes * 8 rows * 2 feature groups * 32-bit word
```

每个 row/group 是 single-port SRAM。read 根据全局 feature 同时读取 stripe 的 8 rows；
right-edge write 根据每行 tag 独立选择 group/offset。仿真断言禁止同一周期读写同一
物理 row/group。未选 group 的 enable 保持低，减少 SRAM 动态功耗。

持久化 O-bank 的关键收益是：非首 KV tile 不再逐 row、逐 feature-group preload
整个 O tile。每个 feature `d` 只在 V[:,d] 即将进入阵列时读取一次 O_old[:,d]，计算
完成后原位写回 O_new[:,d]。

## 16. Final Normalization

只有最后一个 KV tile 才扫描 O-bank。顶层按 `stripe -> feature` 顺序请求：一次读取
8 个 rows 的 O 和同一 8-row slice 的 l。

### 16.1 `reciprocal_lut`

每个 normalizer lane 有一个 reciprocal unit：

1. 找到 32-bit denominator `l` 的最高有效位。
2. 将最高位归一到 bit 15 附近。
3. 用 `normalized[14:11]` 查 16-entry reciprocal seed。
4. 按原 exponent 左/右移恢复尺度并饱和到 32 bit。

它是 LUT seed 近似，没有 Newton-Raphson refinement。零 denominator 输出零。

### 16.2 `online_normalizer`

一个实例有 8 lanes，所有 stripe rows 同时处理，一个 feature/cycle：

1. O、scale、tag 延迟到 reciprocal response。
2. 计算 signed `O * reciprocal`，再 arithmetic shift 15。
3. 根据已证明的数值范围保留 conservative signed 48-bit operand。
4. latency-2 48x16 multiplier 施加 `out_scale`。
5. shift、guard/sticky round 和 signed INT8 saturation。

每个 lane 的 arithmetic payload 由 valid 保护而不复位。stripe/feature tag 穿过所有
流水级，输出端不需要依赖实时 counter 猜测数据归属。

## 17. Output Packing and AXI Writeback

### 17.1 `output_buffer`

Normalizer 以 feature-major 顺序输出 8 rows。每行有一个 256-bit `pack_q`。新 INT8
byte 总是插入固定高端，旧内容右移；32 features 后，feature 0 位于低 byte，形成
与 SRAM/AXI 一致的 row word。这样没有 32-way dynamic byte write mux。

group 完成后，8 个 `pack_q` 逐周期破坏性移到 `pack_q[0]` 并写 output SRAM，消除
8:1 256-bit row selector。地址为：

```text
output_word_addr = global_row * GROUPS + feature_group
```

最后不足 32 features 的 group 使用 zero padding。仿真断言要求 feature offset
严格递增，防止上游乱序造成静默 byte permutation。

stream 阶段按 output memory 地址递增，每个 256-bit word 分成低/高两个 128-bit
beats。`stream_strb_o` 能计算最后不足 16 bytes 的精确 byte strobe；但当前顶层没有
把它接到 `axi4_master_write`，writer 的 WSTRB 固定全 1。默认 `HEAD_DIM=64`、
`OUT_W=8` 时每行 64 bytes，写回总长总是 16-byte 整数倍，因此当前支持配置不会
产生 partial beat。若扩展任意 HEAD_DIM，必须先给 writer 增加 source strobe 输入。

### 17.2 `axi4_master_write`

Writer 一次只允许一个 outstanding burst：

```text
IDLE -> AW -> W -> B -> AW/W/B ... -> DONE
```

burst size 是以下三者最小值：剩余 beats、配置 burst length（当前 16）、4-KB
边界前剩余 beats。数据源只在真实 `WVALID && WREADY` 时前进。任意非 OKAY B response
进入 ERROR。base address 必须 16-byte aligned。

## 18. Clock Gating, Reset and Power Intent

`fa_clock_gate` 是 backend-portable wrapper：

- ASIC：实例化 characterized `CKLNQD4BWP12T30P140` ICG。
- FPGA：保持 root clock，依靠 FF/BRAM/DSP clock-enable inference。

顶层有 array、normalizer、output 三个 enable domain。阵列内部还有一个 control/exp
clock branch 和每 stripe 一个本地 branch，以限制单一 gated-clock fanout。enable
覆盖 pipeline drain，不能在最后一个 input valid 后立即关钟。

Reset policy：

- FSM、valid、错误和外部可见状态使用 reset。
- valid-qualified datapath payload 通常不复位。
- PE Score/P 是 phase state，使用同步 clear。
- `fa_clear_replica` 每 8 columns 复制一个 QK clear token，避免全局 clear 直接驱动
  大量 PE；模块边界阻止等价合并，但内部 flop 仍可映射到标准单元。

SRAM 低功耗规则：未选 bank/group 的 CEB 保持关闭；partial write 只 enable 目标 banks；
单端口 memory write 优先于 read；idle 时输出和 datapath payload 尽量保持不翻转。

## 19. Error and Performance Observability

顶层 `fatal_error_w` 汇总 cache protocol、array controller、QK/PV engine、softmax 和
AXI writer error。Scheduler 进入 ERROR，regfile 保存 sticky error code，`irq_o` 在
done 或 error 时拉高。

`perf_counter` 统计：

- scheduler busy cycles；
- load/writeback stall cycles；
- QK/PV active cycles 乘默认 1024 MACs；
- 完成的 KV tile 数。

这些 counter 是事件估算，不等价于门级真实 multiplier toggle count。

## 20. SRAM Macro Composition

ASIC `asic_sram_256xwide` 用 byte slices 拼接 `uhdsp_256x8m4s`：CEB/WEB 为低有效，
未使用的 test/sleep pins 固定到 functional mode。`asic_sram_1024x16` 用 4 个 depth
slices、每 slice 2 个 byte macros 组成 1024x16，只 enable 被地址 `[9:8]` 选中的
slice。

默认顶层共有 480 个 256x8 macros：

| Owner | Macro count derivation | Count |
| --- | --- | ---: |
| Q/K/V ping-pong cache | 6 memories * 16 banks * 2 bytes | 192 |
| Persistent O-banks | 4 stripes * 8 rows * 2 groups * 4 bytes | 256 |
| Output buffer | one 256-bit word / 8-bit | 32 |
| Total | | 480 |

FPGA 分支保持相同逻辑布局和同步 read contract，但分别推断 URAM/BRAM。

## 21. Reusable but Inactive Modules

此前未接入顶层的 generic requantizer/FIFO/BRAM/URAM wrappers 已从 RTL、
filelist 和 module-TB 清单删除。当前文件树只保留现有加速器数据流实际使用的模块。

## 22. Current Implementation Boundaries

1. 当前硬件实现固定 32x32 prefill MHA；decode 和 GQA 会被 START validation 拒绝。
2. Q/K/V base 和 stride 已有寄存器，但没有 AXI read DMA；tile loader 位于顶层外部。
3. `cfg_value_scale_w` 和 `cfg_mask_cfg_w` 已锁存但当前 datapath 未消费。
4. `cfg_q_base_w`, `cfg_k_base_w`, `cfg_v_base_w` 不参与当前 cache 地址生成；
   fused array 的 mask 使用 tile index 生成的 logical `q_base/k_base`。
5. reciprocal 和 exp 都是查表/PWL 近似，精度必须通过系统级 golden model 验证。
6. O-bank 和部分 cache memory 是 single-port；调度必须保持文中说明的 read/write
   互斥。ASIC 更换 SRAM macro 时必须保持 wrapper 的同步 latency contract。
7. `HEAD_DIM` 可参数化，但 cache word lanes 必须等于 ARRAY_ROWS/COLS，stripe rows
   必须整除 ROWS，当前 array 还要求 ROWS==COLS。
8. AXI write address 是 32 bit；虽然软件寄存器保存 64-bit O base，当前顶层只使用
   `cfg_o_base_w[31:0]`，不能写到 4-GB 地址空间以上。
9. Output buffer 的 partial-beat strobe 尚未接入 write master；当前固定 64-byte row
   不受影响，任意非 16-byte 对齐输出长度尚未得到顶层支持。

## 23. Recommended Code Reading Order

建议按以下顺序逐步在代码中追踪同一个 valid token：

1. `attention_defines.vh`：先记住 widths、states 和 register map。
2. `attention_accel_top.v`：画出 scheduler level、start pulse 和 completion pulse。
3. `accel_scheduler.v`：理解 head/Q/KV 三层 index 的推进条件。
4. `qkv_tile_cache.v`：确认一个 address 对应一个 feature 和 32 lanes。
5. `fsa_qk_engine.v`：追踪 cache request/response counter。
6. `fsa_fused_array.v` 的 skew 和 stripe instances。
7. `fsa_fused_pe.v`：逐 phase 查看 `accum_q`, `prob_q`, `sum_data`。
8. `fsa_stripe.v`：追踪 max left-to-right、m right-to-left、sum 两种方向。
9. 回到 `fsa_fused_array.v`：追踪 column tag 经过 scale+exp 后写回 P。
10. `fsa_pv_engine.v` 和 O-seed alignment：追踪 feature tag `d` 到 O-bank write。
11. `online_normalizer.v`、`output_buffer.v`、`axi4_master_write.v`。

调试波形时最有价值的信号组是：

```text
scheduler: state, head_index, q_tile_index, kv_tile_index
QK: qk_valid, qk_last, qk_completion, max_ready_rows
softmax: softmax_state, delta_col_valid/index, prob_write_valid/col
row state: m_rows, alpha_rows, sum_rows, l_rows, row_state_valid
PV: pv_feature, pv_issue_valid, stripe_pv_seed_valid, sum_right_valid/tag
normalization: norm_rd_valid/tag, reciprocal_valid, scale_product_valid
writeback: norm_group_done, stream_valid/ready/last, AXI AW/W/B handshake
```

掌握这条 token/tag 路径比只观察 payload 数值更重要：本设计大量 payload 寄存器
在 invalid 时保持旧值，只有配套 valid 为 1 时其内容才具有架构意义。
