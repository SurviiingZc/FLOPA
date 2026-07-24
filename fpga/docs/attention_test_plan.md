# VCK190 Attention 实测与 LLM 对比测试计划

## 1. 文档目的

本计划定义两类板级 workload：

1. 既定的 Re10K Transformer Attention 子层；
2. 能够在 VCK190 PS 端独立运行、并可将 Attention 子层替换为本设计 PL
   加速器的真实 LLM。

测试的核心不是只测一个 QK tile，而是把 **PS 软件基线、PS+PL Attention
   kernel、PS+PL 完整模型路径** 分开记录，从而同时回答：

- Attention kernel 本身加速了多少；
- AXI/tile loader/PS 驱动开销占多少；
- 加速器接入后完整 LLM 的 prefill 吞吐是否提升；
- 定点误差是否改变模型输出；
- VCK190 板上频率、带宽、功耗和资源是否满足设计假设。

本计划第一阶段只要求完成 **batch=1、prefill、MHA-compatible** 板级流程。
当前 RTL 的启动检查要求 `num_q_heads == num_kv_heads`，因此明确拒绝原生
GQA。RTL 已实现 `seq_q=1`、单个 32-token KV tile 的 MHA decode，并有 UVM
smoke、随机和回压验证；但 DMA/PS 集成、多 KV tile decode 和板级性能尚未
完成，首轮板级结果仍必须标为 prefill-only。

## 2. 推荐工作负载

### 2.1 Workload A：Re10K（必须保留）

| 项目 | 首测配置 |
| --- | --- |
| 网络 | Re10K Transformer |
| Attention 形式 | MHA |
| sequence length | 8192（真实 Re10K 激活）；32、64、144、576（短序列回归） |
| hidden size | 576 |
| Q/K/V projection | `576x576` |
| Q heads / KV heads | 9 / 9 |
| head dimension | 64 |
| 单 head Q/K/V 激活 | `8192x64` |
| batch | 1 |
| 数据格式 | 模型导出的 INT8 Q/K/V，按现有定点协议 |
| 重点层 | 现有 Re10K dump 对应的 `up/down_blocks_2_*` Attention 层 |

数据优先使用已有文件，不重新随机造数据：

```text
/home/project/public_fpga/FPGA25_ARIES_AE/dfot_fpga/dfot_test/aie_bins
/home/project/public_fpga/FPGA25_ARIES_AE/dfot_fpga/dfot_test/attention
```

首轮要同时保存已有 Q、KT、V、prob dump 和硬件输出，先做 QK、softmax、PV
分段对拍，再做完整 QK+softmax+PV 对拍。

注意：Re10K 的 `hidden=576` 是投影矩阵和 token embedding 的 hidden 维度，
不是 sequence length。真实激活序列长度为 `seq_len=8192`；因此每个 head
的 Q、K、V 形状为 `8192x64`，完整 MHA 的 Q/K/V 形状为 `8192x576`。
`32/64/144/576` 只用于 tile 尾块、模块回归和 bring-up，不能写入真实
Re10K 性能结果的 sequence length 栏。

### 2.2 Workload B：SmolLM2-135M-Instruct（推荐 LLM）

选择理由：模型很小，适合 VCK190 的双核 Cortex-A72 PS 端做完整推理；模型
是标准 Llama 架构，容易使用 AArch64 C/C++ 推理运行时；更重要的是它的
`hidden_size=576`、`num_attention_heads=9`、`head_dim=64` 与当前 Re10K
和 32x32 阵列完全对齐。官方配置同时给出 `num_key_value_heads=3`，因此它
还是一个有实际意义的 GQA workload，而不只是重复测 MHA。

| 项目 | 配置 |
| --- | --- |
| 模型 | `HuggingFaceTB/SmolLM2-135M-Instruct` |
| 模型架构 | `LlamaForCausalLM` |
| 参数规模 | 约 135M |
| layers | 30 |
| hidden size | 576 |
| Q heads / KV heads | 9 / 3 |
| head dimension | 64 |
| 原生最大位置长度 | 8192；首轮只测到 2048 |
| 首轮运行格式 | PS 端 GGUF Q8_0 或等价 AArch64 量化格式 |
| Attention 输入 | RoPE 后 Q/K、V，转换到 accelerator INT8 定点格式 |

#### 当前 RTL 的兼容配置

当前 `accel_regfile.v` 的 `start_cfg_valid_w` 要求 MHA，即 Q heads 等于 KV
heads。因此首轮上板不能直接把模型的 3 个 KV heads 送入 PL。采用如下
**MHA-compatible expansion**：

```text
model KV head 0 -> accelerator KV heads 0,1,2
model KV head 1 -> accelerator KV heads 3,4,5
model KV head 2 -> accelerator KV heads 6,7,8
```

复制发生在 PS 的 tile packer 中，PL 配置成 `num_q_heads=9,
num_kv_heads=9`。这会增加 KV 读取和 PL 计算量，但不改变 Q/K/V 的数值，
并且可以在不修改当前 RTL 的前提下得到第一组真实 LLM 结果。报告中必须把
该复制开销单独列出。

第二阶段再将 RTL 改为 `num_q_heads=9、num_kv_heads=3`，对比：

1. MHA-compatible expansion；
2. 原生 GQA；
3. PS-only GQA。

### 2.3 为什么不把大模型作为首轮主模型

1B 以上模型会把主要时间和内存压力转移到 PS 端的 embedding、MLP 和权重
搬运，难以区分 Attention 加速收益。SmolLM2-135M 足以完成真实 tokenization、
prefill、KV cache 和 autoregressive decode 的软件闭环，同时保持 Attention
张量与现有 576/9/64 设计一致。TinyLlama/Qwen 等 GQA 模型可作为后续扩展，
但不应先于当前接口兼容性收敛。

## 3. VCK190 PS/PL 测试平台

### 3.1 平台事实与时钟档位

VCK190 使用 XCVC1902，PS 为双核 Arm Cortex-A72；板级设计通过 DDR/NoC
提供 PS 访问的外部内存。PL 时钟按工程已有约束采用三档：

| 档位 | 用途 |
| --- | --- |
| 150 MHz | 上板 bring-up 保底 |
| 200 MHz | 首版性能基线 |
| 250/300/312.5 MHz | 仅在 post-route timing 通过后记录 |

频率必须来自 Vivado post-route 报告，不把 312.5 MHz 写成保证值。每个
结果表同时记录 `FREQ_PL`、Vivado timing WNS/TNS 和 bitstream git revision。

### 3.2 PS 软件栈

推荐使用 Linux AArch64 运行完整模型，原因是模型文件、prompt、日志和 DMA
buffer 管理更方便；PL 微基准可另外提供 bare-metal/UART 版本。PS 端至少
包含：

- AArch64 C/C++ 模型运行时（优先使用 llama.cpp 或同等 Llama/GGUF 运行时）；
- `attention_accel` 用户态驱动或 UIO/Vitis driver；
- AXI4-Lite 寄存器访问；
- 128-bit tile packer/DMA；
- cycle counter、PMU counter 和温度/功耗采样接口。

llama.cpp 的 CPU 路径使用纯 C/C++，并提供 ARM NEON 等 CPU 优化；实际板上
仍需执行一次 native PS smoke test，不能只因模型可以在开发机加载就宣称
VCK190 PS 可运行。

### 3.3 必须补齐的 PL wrapper

当前 `rtl/attention_accel_top.v` 的接口是：

- AXI4-Lite 32-bit control；
- `tile_load_*` 128-bit、带 kind/bank/address/half/valid/ready 的 tile-loader
  侧带接口；
- 128-bit AXI4 master writeback。

它不是可直接连接 PS DDR 的 AXI read master。因此 Vivado block design 必须
增加：

```text
PS DDR/NoC
   -> AXI DMA MM2S (or custom AXI4-to-tile-loader)
   -> 128-bit tile_load_* wrapper
   -> attention_accel_top
attention_accel_top AXI4 master write
   -> NoC/DDR output buffer
```

AXI4-Lite 只负责配置和状态，不把大块 Q/K/V 通过寄存器写入。驱动必须维护
cache coherency：DMA 前 flush input buffers，DMA 完成后 invalidate output
buffers，并使用物理地址或连续 DMA buffer。

## 4. 三种必须分开的基线

每个 workload、sequence length、layer 和 clock 档位都要运行以下三种模式：

| 模式 | 说明 | 是否包含搬运 |
| --- | --- | --- |
| `PS_NATIVE` | PS 上完整模型的原生 Attention/推理运行时 | 是，模型自身内存访问 |
| `PS_INT8_REF` | PS 上与 PL 完全相同的 INT8 QK + online-softmax + PV 参考 kernel | 是，软件 pack/unpack 可单独计时 |
| `PS_PL_E2E` | PS 调度 + DMA/tile-loader + PL Attention + writeback | 是，系统最终结果 |
| `PS_PL_KERNEL` | 只统计 PL 从 tile commit 到 writeback done 的周期 | 否，隔离硬件核心 |

`PS_NATIVE` 用于回答“完整 LLM 是否更快”；`PS_INT8_REF` 用于回答“硬件和
软件是否比较了相同算法/定点格式”；`PS_PL_KERNEL` 用于回答“RTL 核心本身
的吞吐”；`PS_PL_E2E` 才是最终可交付的板级结果。不能只报告 kernel-only
加速比而称为完整模型加速。

## 5. 数据采集和文件格式

### 5.1 LLM 采样位置

对每个被测层，采集 **RoPE 完成之后、softmax 之前** 的：

- `Q[row, head, dim]`；
- `K[key, head, dim]`；
- `V[key, head, dim]`；
- causal mask 和有效 query/key 长度；
- 每个 head/tensor 的 INT8 scale、zero-point、round/saturate 配置。

不要采集 RoPE 前的 Q/K，也不要把 projection 权重直接当作 Attention 输入。
硬件对拍的输入必须与软件 Attention kernel 的输入边界一致。

### 5.2 推荐的样本目录

大数据不直接提交 Git；使用 manifest + hash，样本放在板卡可访问的外部存储。

```text
FPGA/data/
  re10k/
    manifest.json
    layer_<id>/q.bin
    layer_<id>/k.bin
    layer_<id>/v.bin
    layer_<id>/golden_o.bin
  smollm2_135m/
    manifest.json
    prompt_<id>/layer_<id>/q.bin
    prompt_<id>/layer_<id>/k.bin
    prompt_<id>/layer_<id>/v.bin
    prompt_<id>/layer_<id>/golden_o.bin
```

每个 `manifest.json` 至少包含：

```json
{
  "model_id": "HuggingFaceTB/SmolLM2-135M-Instruct",
  "revision": "<immutable commit hash>",
  "layer": 0,
  "seq_q": 128,
  "seq_kv": 128,
  "head_dim": 64,
  "num_q_heads": 9,
  "num_kv_heads_model": 3,
  "num_kv_heads_accel": 9,
  "tile_q": 32,
  "tile_k": 32,
  "dtype": "int8",
  "q_scale": "<per-tensor-or-per-head value>",
  "k_scale": "<value>",
  "v_scale": "<value>",
  "mask": "causal",
  "sha256": {"q": "...", "k": "...", "v": "...", "golden_o": "..."}
}
```

256-bit 内部 cache word 必须按两个 128-bit beats 存储，明确记录 little-endian
lane 顺序。所有输入地址 128-bit 对齐；尾 tile 仍按 32-lane 结构写入并由
valid/mask 标记，不允许用未初始化字节填充有效计算。

### 5.3 采样集合

| 集合 | 序列长度 | 层采样 | 重复次数 | 目的 |
| --- | --- | --- | --- | --- |
| smoke | 32、64 | layer 0 | 3 seeds | 快速联调和尾块 |
| scaling | 128、256、512、1024、2048 | layer 0、15、29 | 3 seeds | 吞吐/带宽曲线 |
| full-layer | 128、512、1024 | 全 30 层 | 1 固定 seed | 完整模型 prefill |
| prompt-real | 16 个固定 prompt | layer 0、15、29 | 3 runs | 真实 token 分布 |
| re10k-real | 8192 | 既定 `up/down_blocks_2_*` 层 | 1 | 真实 Re10K 板级结果 |
| decode reference | 1 query + KV cache | PS only; optional single-tile PL smoke | 3 runs | 不纳入 PL 首轮 prefill 加速比 |

`prompt-real` 使用 16 个固定 prompt：8 个英文技术问答、4 个中文短问题、
4 个代码补全样本。每个 prompt 保存 tokenizer 版本、token id、长度和 SHA256。
每种长度另生成 deterministic token-id 输入，用来消除自然语言 token 长度和
分支对吞吐的影响。模型输出只作为功能回归，性能主表使用固定 token ids。

## 6. 测试流程

### P0：模型和工具链冻结

1. 固定 SmolLM2 model revision、tokenizer revision、GGUF/权重 SHA256。
2. 固定 Vitis/Vivado 版本、board file、XSA/bitstream revision。
3. 记录 Linux image、kernel、CPU governor、线程绑核和 PL clock。
4. 禁止在同一张性能表中混用不同量化格式或不同 tokenizer。

**退出条件**：PS native runner 能加载模型，完成 16 个 prompt 的一次性
prefill，并输出 token ids、prefill latency 和 peak RSS。

### P1：离线 Attention 提取和黄金模型

1. 从 PS runner 或离线 Python runner 提取 RoPE 后 Q/K/V。
2. 用 FP32/FP16 软件 Attention 保存高精度 `golden_o_fp`。
3. 用与 RTL 相同的 INT8/定点 online-softmax 生成 `golden_o_int`。
4. 对每个 tile 生成 Q/K/V、mask、scale 和 manifest。
5. 首先跑 Re10K 的已有 dump，不修改其原始量化参数。

**退出条件**：`PS_INT8_REF` 与 bit-accurate reference 在所有 smoke/scaling
样本上通过误差阈值。

### P2：RTL/仿真闭环

1. 用现有 module TB/UVM 对 QK、softmax、PV 分段对拍。
2. 覆盖 `seq % 32 != 0`、causal mask、全无效 row、first/non-first KV tile。
3. 验证 MHA expansion 后 9 个 KV heads 的结果与模型 3 个 KV heads 复制结果一致。
4. 记录周期、stall、MAC 和 tile 计数器，确认计数器和软件期望一致。

**退出条件**：无 AXI protocol/error，所有 tile 的 valid/last 和输出 hash 稳定。

### P3：Vivado/VCK190 bring-up

1. 建立 PS、NoC/DDR、AXI4-Lite、AXI DMA/custom loader、PL clock/reset。
2. 先加载一个 32x32x64 tile，检查寄存器读写、IRQ、tile commit 和 writeback。
3. 逐步升至 `seq=64/128/512/1024`，再打开完整 Re10K `seq=8192` 和
   SmolLM2 样本。
4. 每个配置先跑 10 次无计时 smoke，再进入计时区。

**退出条件**：同一输入重复 30 次输出 hash 一致；无 DMA underrun/overrun、
write response error、cache coherency 错误和温度异常。

### P4：Kernel-only 性能

对每个 `seq/head/layer/FREQ_PL`：

1. PS 将 Q/K/V tiles 写入 staging buffer；
2. 计时从最后一个 `tile_commit` 被接受开始；
3. 计时到最后一个 AXI write response 和 accelerator done；
4. 读取 `perf_cycles/stall/mac/tiles`；
5. 将 load、QK、softmax、PV、writeback 阶段分别记录。

重复 30 次，报告 median、P10、P90、min/max，不只报告单次最好值。

### P5：端到端 Attention

将 Q/K/V extraction、MHA expansion、INT8 pack、DMA、PL、unpack 和后续 residual
连接起来，记录：

```text
T_e2e = T_extract + T_pack + T_dma_in + T_pl + T_dma_out + T_unpack
```

另外报告 `T_pl`，这样可以判断瓶颈是 Attention 算力还是 PS/AXI 搬运。

### P6：完整 LLM prefill

1. PS native：完整 SmolLM2 prefill，Attention 不接 PL。
2. PS+PL：只替换 Attention，embedding、QKV projection、RoPE、MLP、norm、
   lm_head 仍由 PS 运行。
3. 首轮只测 batch=1 和 prefill；RTL 单 tile MHA decode 可作为独立 smoke，
   但在 DMA、多 KV tile 和板级性能闭环前不纳入 PL E2E 加速比。
4. 对 layer 0/15/29 先做逐层替换，再做全 30 层替换。
5. 比较 token ids、logits top-1/top-k 和生成文本，避免“性能变快但模型不等价”。

### P7：功耗和长期稳定性

1. 记录 idle、PS-only、PL-kernel、PL-e2e 四种功耗。
2. 每个配置持续运行至少 10 分钟或 1000 次 Attention 调用。
3. 记录板级温度、PL clock、DDR traffic、错误计数和输出 hash。
4. 以 `P_run - P_idle` 计算动态功耗；不要把整板静态功耗冒充加速器功耗。

## 7. 指标和计算方式

### 7.1 延迟和吞吐

```text
prefill_tokens_per_s = seq_q / T_prefill_s
attention_tokens_per_s = seq_q / T_attention_s
speedup = T_PS_baseline / T_PS_PL_e2e
kernel_speedup = T_PS_INT8_REF / T_PS_PL_kernel
```

对于每个 head：

```text
MACs = 2 * seq_q * seq_kv * head_dim       # QK and PV
ops  = 2 * MACs                             # one multiply + one add
effective_GOPS = heads * ops / T_s / 1e9
```

同时报告实际输入带宽：

```text
BW_in  = bytes(Q + K + V + scales) / T_dma_in
BW_out = bytes(O) / T_dma_out
```

### 7.2 正确性

逐层、逐 head、逐 tile 保存：

- `max_abs_error`；
- `mean_abs_error` 和 RMSE；
- cosine similarity；
- INT8 输出饱和比例；
- logits top-1/top-5 一致率；
- full-model 生成 token 一致率（仅作为辅助，不替代数值指标）。

建议首轮验收阈值：

| 层级 | 建议阈值 |
| --- | --- |
| INT8 定点对拍 | bit-exact 或仅允许文档化的 saturate/round 差异 |
| FP16/FP32 对比 | cosine >= 0.99；阈值按 Re10K 校准 |
| LLM logits | top-1 一致率 >= 99%（同一 token 输入） |
| AXI/控制 | 0 protocol error，0 data loss |

阈值不是替代误差曲线；必须同时保存逐层误差和饱和统计。

### 7.3 性能利用率

使用硬件计数器计算：

```text
array_utilization = active_mac_cycles / total_compute_cycles
stall_ratio = perf_stall / perf_cycles
tile_rate = perf_tiles / T_s
```

把 `QK`、`softmax`、`PV`、`load`、`writeback` 分段画成 stacked bar，明确
加速器是受 MAC、softmax、DDR 还是 PS 驱动限制。

## 8. 结果表和图的固定格式

每次实验输出一个 CSV/JSON 记录，至少包含：

```text
date, git_rev, bitstream_rev, model_rev, workload, layer, seq_q, seq_kv,
q_heads, kv_heads_model, kv_heads_accel, head_dim, mode, freq_mhz,
T_ps_native_us, T_ps_int8_ref_us, T_pl_kernel_us, T_pl_e2e_us,
tokens_per_s, effective_gops, bw_in_gbps, bw_out_gbps,
cycles, stall_cycles, mac_count, tile_count, power_idle_w, power_run_w,
temperature_c, max_abs_error, cosine, top1_match, status
```

固定输出图：

1. Re10K 与 SmolLM2 的 Attention latency vs sequence length；
2. PS-native / PS-INT8 / PL-kernel / PL-e2e speedup；
3. QK/softmax/PV/load/writeback 时间分解；
4. effective GOPS、tokens/s 与 PL frequency；
5. DDR bandwidth 与 stall ratio；
6. dynamic power、GOPS/W 和温度；
7. 每层误差、cosine、top-1 match；
8. MHA expansion 与 native GQA（后续版本）对比。

## 9. 验收门槛

### 首轮可交付

- VCK190 PS 能独立跑 SmolLM2-135M-Instruct native prefill；
- Re10K `seq_len=8192, heads=9, head_dim=64` 完整 Attention 上板；
- Re10K 单 head Q/K/V `8192x64`，完整 MHA Q/K/V `8192x576` 的数据采集和对拍通过；
- SmolLM2 `seq=128/512/1024` 的 MHA-compatible expansion 上板；
- `PS_PL_E2E` 输出与 `PS_INT8_REF` 通过误差阈值；
- 30 次重复运行输出 hash 一致；
- 150/200 MHz 至少一档 timing clean；
- 性能表区分 kernel-only 与 end-to-end，不隐藏 loader/driver 开销。

### 第二轮扩展

- RTL 支持 `num_q_heads=9, num_kv_heads=3` 原生 GQA；
- 比较 KV 读流量、tile 数、stall 和 tokens/s；
- 扩展并验证 decode 的 `seq_q=1、seq_kv=128/512/2048` 多 KV-tile 流程；
- 逐步将 Attention 替换扩展到完整 30 层。

## 10. 风险、降级和禁止事项

| 风险 | 影响 | 降级方案 |
| --- | --- | --- |
| PS 运行时无法直接加载 GGUF | 无法做完整 LLM | 先使用固定 token-id + 自研 C++ Attention harness；模型全链路作为后续项 |
| 当前 RTL 不支持 GQA | SmolLM2 KV head 数不匹配 | PS 端复制 KV heads，报告复制开销；不要伪称原生 GQA |
| tile-loader wrapper 尚未集成 | 只能做 RTL 仿真 | 先做 PS memory-to-stream DMA smoke，再做 PL kernel benchmark |
| AXI 搬运成为瓶颈 | E2E 加速比不明显 | 分开报告 kernel-only、DMA-only、E2E，增大 burst 和 staging buffer |
| INT8 误差过大 | LLM logits 漂移 | 保存 FP16/INT8 双 golden，调整 per-head scale/round，不能只放宽阈值 |
| decode 仅完成单 tile RTL 验证 | 不能宣称完整 LLM decode 加速 | 首轮明确标为 prefill-only；decode 先做 PS baseline 和单 tile PL smoke |
| 模型/量化版本漂移 | 结果不可复现 | manifest 固定 commit、tokenizer、权重 SHA256 和 bitstream revision |

禁止以下结果写入最终性能表：

1. 只测预加载 tile、却称作端到端吞吐；
2. 用不同 Q/K/V 定点格式比较 PS 与 PL；
3. 把 GQA KV 复制隐藏在软件预处理时间之外；
4. 把 PS native 模型 token/s 与 PL kernel MAC/s 直接比较；
5. 用仿真估计代替 post-route 频率或板级功耗。

## 11. 参考资料

- AMD VCK190 Evaluation Board User Guide UG1366：
  <https://docs.amd.com/r/en-US/ug1366-vck190-eval-bd/Versal-Adaptive-SoC>
- AMD Versal Architecture and Product Data Sheet DS950：
  <https://docs.amd.com/api/khub/documents/BY0FMkLH05y85Nwu4GmWsw/content>
- SmolLM2-135M 配置（固定 revision 后写入 manifest）：
  <https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct>
- llama.cpp AArch64/C++ CPU runtime：
  <https://github.com/ggml-org/llama.cpp>

以上链接只用于固定平台和模型来源；最终实验仍以服务器缓存的模型、工具链、
bitstream 和 manifest SHA256 为准。
