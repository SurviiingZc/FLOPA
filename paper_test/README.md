# FLOPA ISCAS 实施与 Evaluation 测试计划

更新：2026-10-17。作者已批准按优化文档实施 RTL/UVM 修改、短序列验证和后续综合。
已完成 Fig. 1 的 PixArt-Sigma、DFoT-MCRAFT、Wan2.1 三模型同口径 GPU profiling；
原生模型 ASIC/CPU/GPU 延迟对比尚未开始；本轮首先完成新硬件功能与综合。
RTL 裁剪与 PPA 优化实施计划见 [RTL_OPTIMIZATION_PLAN_ZH.md](RTL_OPTIMIZATION_PLAN_ZH.md)。

2026-10-17 最新决定：物理容量编译期 MAX_D=128，同一实例由 regfile 配置实际 d，
覆盖原生 64/72/128；QK、PV、归一化、loader、输出打包和计数器同步按 d 执行。
撤销分别编译固定 d=64/72 的旧建议。合法范围、job 锁存、72 字节跨行/多头对齐、
SRAM 物理容量代价及验收项已列入优化文档第 4–5 节。
原 N=512 仿真/功耗自动监控已取消，不恢复旧作业。本轮进度与结果见
[IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md)，不运行长序列回归或长 gate-SAIF。

## 本轮代码实施与入口

- 分支：`codex/diffusion-runtime-d`。基线冻结 `4e84950`，构建门槛 `f5a8f0b`，
  RTL 候选 `ee22914`，dense 掩码分解 `021b746`。
- 同一 MAX_D=128 实例支持 d=1–128；native 64/72/128 切换、tail、多头、
  控制/复位及算术共六类短 UVM 已通过：157 个 job、66,312 字节逐字节检查，
  error/fatal 均 0。最终定向模块检查及源码/日志 hash 审计后才启动综合。
- 源码接口与存储：`docs/rtl_runtime_d.md`；UVM 范围：`docs/uvm_runtime_d.md`。
- `make runtime-d-smoke` 复用一个 simv 跑短套件；`make synth-verified` 校验
  已通过日志、源码提交和 hash 后综合。新结果写 diffusion_runtime_d group，
  旧 system group 保留，不覆盖历史基线。
- 新版预期 480 SRAM 宏、28 个真实 ICG，O 为两个完整版本。实际数值以 DC 为准。
  未注入新活动的 `power.rpt` 是 vectorless 估计，不能当作模型 gate-SAIF 功耗。

2026-10-16 模型筛选更新：作者允许按模型原生 workload 调整 head dimension、
缓存容量和分块参数。当前完成模型选择、Fig. 1 profiling 和优化计划；
这是模型选择时的历史状态；当前 RTL/UVM 已开始优化，原生模型 ASIC 性能测试尚未启动。

Fig. 1 新测量使用同一张 A6000、同一 PyTorch 2.9 环境、batch=1、FP16 autocast，
固定噪声层级的 Gaussian latent，3 个输入种子，每种子 10 warmup + 10 实测。
三条曲线均为 self-attention 根模块 CUDA 时间占同次带 hook denoiser 前向时间的比例，
包含 QKV/输出投影和模块内 RoPE，不含文本编码、VAE、采样外循环。
PixArt 扫 512–2048 方图，N=1024–16384；MCRAFT 扫 4–50 帧，N=1024–12800。
中位数端点分别为 29.70%→67.25%、44.81%→62.85%；保留中间长度的波动。
Wan 固定 13 帧（4 个 latent frames），扫 256–1024 方形分辨率，
N=1024–16384，占比 22.48%→52.53%；使用真实预训练权重与零文本 embedding。
原始数据在 13 服务器 `/home/zhangcheng/DiT-FA/results/flopa_fig1_20261016/`
的 `pixart_final`、`mcraft_final`、`wan_final`；论文 data/motivation_scaling 含副本。
这是 denoiser 前向性能 profiling，不是生成质量或新 ASIC 加速结果。

## 1. 论文要回答的问题

Introduction 的现有实测图说明生成模型的 Attention 占比随 latent token 数增长。
Evaluation 要回答另一个问题：在**相同的真实模型 Q/K/V 和相同的 Attention 算子**下，
FLOPA 的单次算子周期和 CPU/GPU 时间如何变化；PE 内 P 驻留、O bank 持久化和
调度重叠分别有哪些可核验的面积、内部搬运与周期证据。

只保留一张新的 Evaluation 主图和一张跨栏 PPA 主表。
原时序窗口图（旧 Fig. 7）与架构流水图重复，已经从论文正文删除。

## 2. 模型和硬件盘点

- 13 服务器：Xeon Gold 6133 CPU、两张 RTX A6000。主图只使用一张 GPU。
- 33 服务器：现有 FLOPA 为 32×32 PE、INT8 Q/K/V、每头 d=64；
  28 nm TT/0.9 V/25°C 映射面积 2.436075 mm²，含 0.656747 mm² SRAM。
  1.60 ns 是综合目标，不是布局布线后的实测最高频率。
- 现有 DiT-XL/2、PixArt-Sigma 的每头 d=72；既有 PixArt 回放把 72 维裁成
  64 维，仅证明局部 tile 的 RTL 正确性，不能作为整模型同算子性能对比。
- 现有 OpenSora STDiT-v3 为时空分解 Attention，不作为 3D full-attention
  主图的 ASIC/CPU/GPU 同算子样本。
- **推荐图像主模型：PixArt-Sigma。** 28 层、16 头、d=72；现有 Diffusers
  checkpoint 的空间 self-attention 是完整稠密 Attention，文本 cross-attention
  单独统计。它直接对应分辨率主线。512/1024/2048 方形图像的 patch token
  数分别为 1024/4096/16384，这是形状关系，不是新的耗时测量。
  正式生成/质量点优先使用相应官方 checkpoint；当前服务器仅确认 1024-MS
  已存在，既有 2K 形状测试不能冒充已完成 2K 原生 checkpoint 的质量验证。
- **推荐视频主模型：DFoT-MCRAFT（DiT/B）。** 它是 Minecraft 数据集上的
  Diffusion Forcing Transformer，不是独立名为 MCRAFT 的通用文生视频架构。
  已核验 variant=full、rope_3d、非因果、12 层、hidden=768、12 头、d=64。
  256×256 输入经 8 倍空间 VAE 压缩和 2×2 patch 后，每帧 256 个 patch；
  50 帧给出 N=12800。现有 functional signature 已捕获
  Q/K/V=[1,12,12800,64]、attn_mask=null、is_causal=false。
  checkpoint 和 ImageVAE 均已在服务器，代码、配置和历史 profiling 完整。
  原生空间尺寸固定，首选通过帧数变化研究 N；不把其曲线称为空间分辨率扫描。
  更短帧数须先核验 RoPE 和采样流程；64 帧/16384 tokens 超出已确认的
  50 帧配置，不能为了横轴整齐直接外推。
- **第三模型：Wan2.1-T2V-1.3B。** 用于补充通用文生视频代表性和
  d=128 的扩展性。官方配置为 30 层、hidden=1536、12 头、全局 self-attention，
  文本 cross-attention 独立。权重已取得，三种子多长度 GPU profiling 已完成。
  新运行时 d 版本将 128 维列入重点硬件验收；原生 ASIC 回放尚未开始。

已确定 PixArt-Sigma + DFoT-MCRAFT 两个主模型，覆盖 2D/3D 完整 Attention
和 d=72/64；加入 Wan2.1 后覆盖原生 d=128。当前 Fig. 1 采用三条实测曲线，
不以 OpenSora 的分解 Attention 代表 full Attention。
Fig. 1 可以采用不同原生 N 点，明确空间分辨率扫描与帧数扫描，不强行匹配非法形状。

MCRAFT 历史记录使用真实 checkpoint、合成初始 latent 和动作条件，统计范围为
denoiser-only；不能声称是真实数据视频生成质量结果。记录中的 Attention 42.17%
使用 self-CUDA 分类占比，与现 Fig. 1 的 module-hook 分母不同，不直接拼到同一曲线。
硬件正式误差评价应从冻结采样流程取得各 step 的模型 Q/K/V，补齐条件数据来源。

模型选择体现优势的依据是：完整 N×N Attention 重复访问 query/KV tile，PE 内 P
驻留可避免共享 P 缓冲往返，O bank 承接跨 tile 累积，调度重叠减少等待。
模型名称或较长 N 本身不保证相对优化 GPU 的速度优势；这些结论须由后续实测支持。
硬件采用 MAX_D=128 的同一实例，以运行时 d 覆盖 64/72/128，检查缩放因子、
尾 feature、缓存、O bank、输出拼接及多头地址。Decode/causal 裁剪与该功能
分别归因，不能用小 d 的低活动量冒充更小的 SRAM 面积。

本地审计来源：
- `/home/zhangcheng/FPGA27_AIE/configs/workloads.yaml`
- `/10T/zhangcheng/FPGA27_AIE_data/unified_9mode/runs/` 下的
  `mcraft_dit_b_no_hg_shapes_formal001/{resolved_config.yaml,functional_signatures.jsonl}`
- `/10T/zhangcheng/FPGA27_AIE_data/runs/` 下的
  `20260801T081000Z_dfot_mcraft_dit_b_plain_formal001/run_manifest.json`
- `/10T/DFoT_down/pretrained_models/DFoT_MCRAFT.ckpt`
- `/10T/DFoT_down/pretrained_models/ImageVAE_MCRAFT.ckpt`

公开来源：
- DFoT：<https://github.com/kwsong0113/diffusion-forcing-transformer>
- PixArt 官方模型列表：<https://github.com/PixArt-alpha/PixArt-sigma#-available-models>
- PixArt d=72：<https://huggingface.co/PixArt-alpha/PixArt-Sigma-XL-2-1024-MS/blob/main/transformer/config.json>
- Wan 配置：<https://github.com/Wan-Video/Wan2.1/blob/main/wan/configs/wan_t2v_1_3B.py>
- CogVideoX：<https://huggingface.co/zai-org/CogVideoX-2b/blob/main/transformer/config.json>

## 3. Evaluation 主图：同输入 Attention 延迟

**建议口径：单个真实模型 Attention head 的完整算子。** FLOPA 是单头引擎；
CPU/GPU 也只处理同一个 head 的同一组 Q/K/V。固定 checkpoint、层、head、
denoising step、prompt 和随机种子。横轴为实际参与该调用的总 token 数 N；
另记录视频 latent token 数及文本 token 数，避免把二者混淆。

- 纵轴：单次 Attention 算子耗时（ms，对数刻度）；三条线分别是 CPU、
  单张 RTX A6000 和 FLOPA。Python 绘图，Times New Roman，单栏宽度。
- CPU：在 13 服务器用明确指定的线程数运行内存中的 Q/K/V，计时仅覆盖
  scaled dot-product Attention；记录算子、软件版本和线程亲和性。
- GPU：同一 Q/K/V 在显存中预热后，用 CUDA event 测算子时间；记录所选
  SDPA/FlashAttention 后端、精度、显存峰值。排除主机到 GPU 的拷贝。
- FLOPA：33 服务器以同一模型张量量化后的 INT8 数据做 UVM RTL 回放。
  记录计算 start 到最后输出的周期；同时单列 Q/K/V 装载到写回的周期。
  图中时间 = 实测周期 × 1.60 ns 综合目标，并直接标注为
  “RTL cycles at synthesis target”，不得称为芯片实测延迟。
  1.60 ns 仅对应当前既有 d=64 网表；硬件调整后的模型必须绑定新的实际约束和
  PPA 报告，不能直接把旧网表数字视为新配置测量。
- CPU FP32、GPU BF16/FP16、FLOPA INT8 的算术精度不同；输入张量、
  掩码与输出形状一致，并相对 FP32 参考报告输出误差。若误差不合格，
  该点不进入速度主图。精度门槛建议在首个 pilot 后、正式扫点前固定。
- 优先试 N=256、512、1024；N=2048 以上只在同模型形状有效、内存与
  仿真耗时可接受时逐点增加。16,384 是探索上限，不插值、不外推，
  不用随机张量冒充模型激活。现有随机 INT8 ASIC 数据不混入主图。
- CPU/GPU 每点固定预热和重复次数，报告中位数及分布；FLOPA 保留
  UVM 通过、输入/输出哈希、周期起止。图注写明这是单 head 算子，
  不代表 30-head 整层或整个视频模型端到端加速。

正式采集前先做一个小规模可行性检查：能否从所选真实模型层提取
完整 Q/K/V、能否由审核后实现的运行时 d RTL 对齐掩码与输出、N=1024 仿真耗时
是否可接受。若不能，不以 d=72 裁剪数据代替真正的同算子比较；
回来重新选模型或收窄图的结论。

## 4. 跨栏 PPA 主表：创新点与证据对应

计划列：设计、工艺、精度、P 中间状态存放位置、SRAM 面积、总面积、
频率、功耗、吞吐或对应工作负载的耗时、PPA 阶段/范围、来源。

| 主张 | 当前可用证据 | 表/正文的呈现边界 |
| --- | --- | --- |
| P 留在 PE 内 | PE P 写次数；无共享 P SRAM 端口 | 可写本设计存储结构；跨设计 SRAM 节省尚未实测 |
| O bank 跨 KV tile 保留输出 | O bank 宏面积 0.350265 mm²、逻辑端口读写计数 | 端口流量不是 DDR 流量，也不是相对别人的节省量 |
| QK/softmax/PV 调度重叠 | row-update/PV 重叠周期和 RTL 串行变体 | 保留一两句量化结果；不再重复架构时序图 |
| ASIC PPA | 已映射面积、N=32–512 gate-SAIF 功耗和周期 | 布局前、综合目标频率、随机 INT8 活动 |
| 实际模型可用性 | 待补真实模型 Q/K/V 回放与数值误差 | 通过后才能与主图相互支持 |

横向对比优先用 H-FA-1-4、H-FA-4-4 和 FSA 原论文数据。
H-FA 的总面积/功耗包含**估算** KV SRAM，但论文没有单列可直接抄用
的 SRAM 面积；FSA 报告的阵列面积**排除** SRAM 和 DMA。因此相关格
写“未单列/不含”，不填 0，也不宣称 FLOPA 的 SRAM 面积小于这些工作。
FLOPA 的 0.656747 mm² SRAM 含 O bank、Q/K/V cache 和输出缓冲；
N=512 gate-SAIF 为 720.4334 mW、4.752 pJ/MAC、0.303186 TOPS，
频率按 625 MHz 综合目标。三者工艺、精度、并行度和 PPA 阶段不同，
不算跨论文速度比或能效排名。

要**直接证明** P 驻留使 SRAM 面积和功耗下降，需要同一 RTL 数据通路、
同一工艺/约束/工作负载的 P-buffer 对照实现，重新综合并做相同 SAIF
功耗回读。原先“不重新综合”仅约束旧基线测试；新版 RTL 的物理 PPA
必须由新综合/时序检查和活动回读提供。未完成对照时只保留结构事实、逻辑端口
计数及明确标注的缓冲下界，不能写成实测节省。若作者决定补强此论点，
需在本方案审核时单独批准该对照实验。

文献来源：<https://arxiv.org/html/2511.00295>（H-FA）；
<https://arxiv.org/html/2507.11331>（FSA）。

## 5. 数据表与验收

本地 `evaluation_data.xlsx` 已缩成两张普通表：
“图_模型算子耗时”放主图待测空格及 Introduction 已用的 15 个同口径实测点；
“表_PPA与机制”放跨设计 PPA、现有 FLOPA 长度扫描和 SRAM 分解。
待测格保持空白；没有原生模型同算子的 CPU/GPU/ASIC 延迟前，不绘制
Evaluation 性能主图。Fig. 1 的模块占比不充当这个性能主图的数据。

每个新点至少保存模型 revision、层/head/step、F/H/W、视频/文本/总 N、
Q/K/V 及输出哈希、精度与缩放、CPU/GPU 算子版本、重复次数、
ASIC UVM 摘要、周期边界和误差结果。只用通过这些检查的行更新图表。

## 6. 已执行的目录清理

按作者要求，2026-10-17 删除 `paper_test` 除 README.md 和
RTL_OPTIMIZATION_PLAN_ZH.md 外全部内容，清理前约 101 MB。
旧实验脚本、编译目录、日志和本目录内摘要不再保留；本轮只重建短验证与综合流程。
工程其他目录的 RTL、DDC、库和综合报告未动。论文目录中的历史结果仅代表旧版，
不能作为新 RTL 的测试结果。自动监控已删除，当前不运行测试。

## 7. 待作者审核的决定

1. 已确定同一 MAX_D=128 实例、regfile 运行时 d；重点覆盖 64/72/128。
   本轮已获批准开工，尚未决定的模型性能图范围不阻碍 RTL/UVM 基础验证。
2. 是否接受**单 head**算子作为三设备延迟图的比较单位？
3. 先做 N=256/512/1024 pilot，较长 N 仅按可行性逐点追加，是否合适？
4. 新 RTL 的 PPA 必须重新综合；是否另加同工艺 P-buffer 对照，直接证明
   P/SRAM 优势，仍待作者确定。

本轮先完成已授权的 RTL/UVM 基础验证与综合；模型性能图实验另行确认，
不把待测格补成估计值。
