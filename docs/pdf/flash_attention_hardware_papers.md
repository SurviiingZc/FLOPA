# FlashAttention 与 Attention 硬件加速器论文整理

整理日期：2026-07-09

本文档收集与本项目相关的 FlashAttention、attention 硬件加速器、FPGA/ASIC
实现论文。优先收录 IEEE/体系结构顶会论文，同时补充若干直接服务本项目架构的
arXiv 预印本。已能公开下载的 PDF 已保存到本目录。

## 1. 结论摘要

对本项目最有参考价值的方向如下：

- FlashAttention 系列提供在线 softmax、block-wise LSE、不落地 S/P 矩阵的
  基本算法依据。
- A3、SpAtten 是 IEEE HPCA 上的 attention/Transformer ASIC 加速代表作，
  可用于对比剪枝、近似和稀疏 attention 的硬件收益。
- SystolicAttention 与本项目的 32x32 阵列、QK/softmax/PV 融合流水最接近，
  可作为 systolic-array 方案的重点参考。
- FAST-Prefill 与本项目 streaming K/V tile cache 思路接近，可用于论证长
  `seq_len` 不缓存全量 KV 的合理性。
- FTRANS、Auto-ViT-Acc 虽不是 FlashAttention，但能提供 FPGA 上完整
  Transformer/ViT 加速、量化和片上缓存组织的参考。

## 2. 已下载 PDF

| 文件 | 论文 |
| --- | --- |
| `2022_flashattention.pdf` | FlashAttention |
| `2023_flashattention2.pdf` | FlashAttention-2 |
| `2024_flashattention3.pdf` | FlashAttention-3 |
| `2020_a3_hpca.pdf` | A3 |
| `2021_spatten_hpca.pdf` | SpAtten |
| `2020_ftrans_fpga.pdf` | FTRANS |
| `2022_auto_vit_acc_fpga.pdf` | Auto-ViT-Acc |
| `2024_sofa_sparse_flashattention.pdf` | SOFA |
| `2025_systolicattention.pdf` | SystolicAttention |
| `2026_fast_prefill_fpga.pdf` | FAST-Prefill |

## 3. 核心算法与 GPU FlashAttention 系列

### 3.1 FlashAttention

- 名称：FlashAttention: Fast and Memory-Efficient Exact Attention with
  IO-Awareness
- 出处：NeurIPS 2022
- 链接：https://arxiv.org/abs/2205.14135
- PDF：`2022_flashattention.pdf`
- 简介：提出 IO-aware exact attention。核心思想是分块读取 Q/K/V，在片上
  SRAM 中维护在线 softmax 的 row max 和 row sum，避免把完整 S/P 矩阵写回
  HBM。该算法是本项目 block-wise LSE、在线归一化、S/P 不落地的基础。
- 对本项目启发：可直接映射为 `Q tile -> K/V tile -> QK -> online softmax
  -> PV -> O_acc` 的流式数据流。

### 3.2 FlashAttention-2

- 名称：FlashAttention-2: Faster Attention with Better Parallelism and Work
  Partitioning
- 出处：arXiv 2023；后续被广泛作为 FlashAttention 改进版本引用
- 链接：https://arxiv.org/abs/2307.08691
- PDF：`2023_flashattention2.pdf`
- 简介：优化 FlashAttention 的并行划分和非矩阵乘法开销，减少 rescale、
  bound check 等非 matmul 操作，提升 GPU 上的实际吞吐。
- 对本项目启发：硬件中应减少 softmax rescale 路径的串行瓶颈，把 exp、
  LSE、O_acc 更新做成清晰流水。

### 3.3 FlashAttention-3

- 名称：FlashAttention-3: Fast and Accurate Attention with Asynchrony and
  Low-precision
- 出处：arXiv 2024
- 链接：https://arxiv.org/abs/2407.08608
- PDF：`2024_flashattention3.pdf`
- 简介：面向 Hopper GPU，强调异步流水、低精度 FP8、GEMM 与 softmax 的
  overlap。虽然目标是 GPU，但对软硬件协同流水很有参考价值。
- 对本项目启发：本项目的 QK、softmax、PV 可以用 valid/ready 流水和
  ping-pong K/V tile cache 尽量重叠。

## 4. IEEE/体系结构顶会硬件加速器

### 4.1 A3

- 名称：A3: Accelerating Attention Mechanisms in Neural Networks with
  Approximation
- 出处：IEEE HPCA 2020
- 链接：https://arxiv.org/abs/2002.10941
- PDF：`2020_a3_hpca.pdf`
- 简介：面向 attention 机制的近似硬件加速器，通过候选筛选和近似减少注意力
  计算量。它不是 FlashAttention 数据流，但代表了 attention ASIC 加速的早期
  顶会工作。
- 对本项目启发：可作为“近似 attention vs exact online softmax”的对比对象。
  本项目若只做精确 attention，可强调没有牺牲 attention 语义。

### 4.2 SpAtten

- 名称：SpAtten: Efficient Sparse Attention Architecture with Cascaded Token
  and Head Pruning
- 出处：IEEE HPCA 2021
- 链接：https://arxiv.org/abs/2012.09852
- PDF：`2021_spatten_hpca.pdf`
- 简介：针对 Transformer 推理提出 token pruning 和 head pruning 的级联稀疏
  attention 架构，减少无效 token/head 的计算和访存。
- 对本项目启发：本项目第一版可做 dense MHA；后续 GQA 或稀疏 token mask
  可参考 SpAtten 的动态裁剪思想。

## 5. FPGA 与 RTL 直接相关工作

### 5.1 SystolicAttention

- 名称：SystolicAttention: Fusing FlashAttention within a Single Systolic
  Array
- 出处：arXiv 2025
- 链接：https://arxiv.org/abs/2507.11331
- PDF：`2025_systolicattention.pdf`
- 简介：提出在单个脉动阵列中融合 FlashAttention 的 QK、softmax 和 PV。
  论文关注减少中间数据移动，并提供 systolic-array 级别的数据流设计。
- 对本项目启发：与本项目 32x32 INT8 阵列、32 lane softmax、streaming K/V
  tile cache 的思路高度相关，是后续微架构细化的重点参考。

### 5.2 FAST-Prefill

- 名称：FAST-Prefill: An FPGA-based Accelerator for the Prefill Stage of LLM
  Serving with Multi-level Dataflow Optimization
- 出处：arXiv 2026
- 链接：https://arxiv.org/abs/2602.20515
- PDF：`2026_fast_prefill_fpga.pdf`
- 简介：面向 LLM prefill 阶段的 FPGA 加速器，核心关注长上下文下 attention 的
  数据流、多级缓存和带宽优化。
- 对本项目启发：可用于支撑 streaming K/V tile cache 的方案，即不缓存完整
  KV，而是按 tile 流式处理更长 `seq_len`。

### 5.3 FTRANS

- 名称：FTRANS: Energy-Efficient Acceleration of Transformers using FPGA
- 出处：arXiv 2020
- 链接：https://arxiv.org/abs/2007.08563
- PDF：`2020_ftrans_fpga.pdf`
- 简介：面向 FPGA 的 Transformer 加速框架，结合模型压缩和硬件架构优化，
  给出 FPGA 相比 CPU/GPU 的性能和能效对比。
- 对本项目启发：可作为 FPGA 上 Transformer 量化、片上缓存、系统级吞吐和
  能效评估的背景参考。

### 5.4 Auto-ViT-Acc

- 名称：Auto-ViT-Acc: An FPGA-Aware Automatic Acceleration Framework for
  Vision Transformer
- 出处：arXiv 2022
- 链接：https://arxiv.org/abs/2208.05163
- PDF：`2022_auto_vit_acc_fpga.pdf`
- 简介：面向 Vision Transformer 的 FPGA 自动化加速框架，涉及 ViT 的量化、
  搜索和 FPGA 资源约束下的映射。
- 对本项目启发：可用于比较 Re10K/Transformer attention 加速与 ViT 加速中
  QKV、softmax、GEMM 的资源占比。

## 6. 稀疏、长上下文与 FlashAttention 扩展

### 6.1 SOFA

- 名称：SOFA: Sparsity and Low-Rank based Flash Attention for Efficient LLM
  Inference
- 出处：arXiv 2024
- 链接：https://arxiv.org/abs/2407.10416
- PDF：`2024_sofa_sparse_flashattention.pdf`
- 简介：探索稀疏和低秩机制下的 FlashAttention 加速，目标是提升 LLM 推理
  中 attention 部分的效率。
- 对本项目启发：第一版不建议引入稀疏/低秩，但可作为后续“长序列减少 K/V
  tile 访问”的优化方向。

## 7. 与本项目方案的对应关系

| 本项目模块 | 主要参考 |
| --- | --- |
| 在线 softmax、block-wise LSE | FlashAttention、FlashAttention-2 |
| BF16/FP-like exp 与归一化流水 | FlashAttention-3、FlashAttention-2 |
| 32x32 脉动阵列融合 QK/PV | SystolicAttention、A3 |
| streaming K/V tile cache | FlashAttention、FAST-Prefill |
| 稀疏/GQA 后续扩展 | SpAtten、SOFA |
| FPGA 量化和端到端评估 | FTRANS、Auto-ViT-Acc |

## 8. 建议阅读顺序

1. 先读 FlashAttention，弄清楚 online softmax 和 LSE 递推。
2. 再读 SystolicAttention，关注如何把 FlashAttention 放入脉动阵列。
3. 读 SpAtten/A3，理解 ASIC 顶会中 attention 硬件加速的评价口径。
4. 读 FAST-Prefill，支撑本项目的 streaming K/V tile cache 论证。
5. 最后读 FTRANS/Auto-ViT-Acc，补 FPGA 系统实现和能效评估背景。

## 9. 备注

- HPCA 属于计算机体系结构顶会，A3 和 SpAtten 是本清单中最典型的
  IEEE/体系结构顶会 attention 硬件论文。
- FlashAttention 系列本身主要是 GPU/算法论文，但本项目的数据流、LSE 和
  S/P 不落地都直接来自该系列。
- 部分 2025/2026 论文目前是 arXiv 预印本，适合做方案参考，不宜在文档中
  当作已正式录用的 IEEE 顶会论文表述。
