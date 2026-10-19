> 2026-10-19 执行更新：用户要求先完成本轮实验，再优化数值。旧数值门槛不再阻断工程性能/功耗/对照测试，误差与溢出统计仍保留。逐字节功能、协议、哈希和功耗活动窗口仍需核验。详见 PRECISION_DEFERRAL_20261019_ZH.md 与 experiments/20261018/LATEST_RUN_20261019_ZH.md。

# FLOPA：ISCAS Evaluation 详细实验计划（2026-10-18执行版）

日期：2026-10-18。作者已确认模型组合、完整多头口径及允许匹配对照和重新综合。
作者已要求按计划开始；本轮采用下文长度、数值门槛及短功耗微基准协议。
方案制定阶段的盘点保留如下；最新执行状态见experiments/20261018/STATUS_ZH.md。
后续以本文件作为 Evaluation 计划；旧随机 INT8、旧 d=64 和旧 FPGA 结果仅为历史记录。

## 1. 论文论点和实验分工

本计划要检验：在高分辨率扩散 Transformer 的实际 SDPA 输入下，FLOPA 的局部
P/O 状态与调度方式如何影响周期、内部搬运、总面积和能量，以及数值代价是否可接受。
CPU/GPU 主图负责定位实际算子性能；同条件硬件对照负责解释收益来源。
不同工艺/精度/存储范围的文献数据用于定位，不预设 FLOPA 获得总面积或能效第一。

| 术语 | 本计划的固定含义 |
| --- | --- |
| SDPA | QK、softmax、PV；不含 QKV/输出投影、QK norm、RoPE、文本编码、VAE |
| N | 进入一次 SDPA 的 patch token 总数，不是输入像素数或单帧 token 数 |
| P | PE 中 max-shifted、未归一化的 Q1.15 权重；不是最终归一化 Attention 矩阵 |
| 原形算子向量 | 从对应完整输入形状的模型调用获取全部 Q/K/V，不裁 N 或 d |
| 功耗微基准 | 明确缩短上下文/头数的硬件表征工作负载，不冒充原形算子 |
| ASIC 时间 | RTL 周期乘映射综合目标周期，不是芯片实测时间 |

### 1.1 作者已确认的三项决定

1. PixArt-Sigma + Wan2.1 进入主图，DFoT-MCRAFT 补充 d=64 正确性/兼容性。
2. 使用完整多头 SDPA；不是单头时间乘头数。建议具体采集为 B=1、conditional branch。
3. 允许保留 F0 的同时新增匹配对照并重新综合、回读活动功耗。
   2026-10-18开始执行；批准实验范围不代表任何待测结果已取得。

## 2. 冻结硬件与软件环境

| 项目 | 本次只读核实的环境 / 实验约定 |
| --- | --- |
| 模型、CPU/GPU服务器 | 10.2.255.13，现有 DiT-FA 工程与已下载权重 |
| CPU | 双路 Xeon Gold 6133，2×20 个物理核，80 个逻辑线程；不以 Cortex-A72 作为主基线 |
| GPU | 单张 RTX A6000，49140 MiB；从两张卡中固定一张空闲设备，记录 UUID |
| 已有 profiling 软件 | PyTorch 2.9.0+cu128，CUDA 12.8，driver 550.144.03；正式采集时再次记录实际版本 |
| ASIC 工程 | 10.1.33.33:/data/workspaces/zhangcheng/flash_attention |
| 当前 RTL 基线 | codex/diffusion-runtime-d；本计划开始时 HEAD=8801e1c，新增文档提交不改变 RTL |
| 实际映射输入 | fc9e921；后续格式整理有等价证明；PPA 不能改写成其他 RTL 的结果 |
| ASIC 条件 | 28 nm TT / 0.9 V / 25°C，MAX_D=128，32×32 PE，480 SRAM 宏 |
| 暂用周期 | 1.60 ns / 625 MHz；只有 setup 目标通过，hold/min-cap 尚未物理收敛 |

CPU 主基线用优化 SDPA FP32。预先固定线程候选 {1,4,8,16,20,40}，先以独立 pilot
按 N 选择最快的合法线程/亲和性组合，再冻结正式测量配置；记录 NUMA 和物理核映射。
不强制使用在该 CPU 上低效的 FP16，也不拿单线程慢实现作为唯一基线。
GPU 使用 FP16 SDPA，先检查 FLASH/EFFICIENT/MATH 后端的可用性与正确性，
冻结最快的合格实现；记录实际 kernel，不假定配置开关就代表使用了 FlashAttention。
CPU/GPU 精度与 FLOPA INT8 不同，主图必须写明，并受第 5 节质量检查约束。
统一 eval/inference mode、dropout=0、is_causal=false、attn_mask=None。
CPU/GPU先完成输入布局与dtype准备再计时，测试过程中不重新加载模型或分配大tensor。

## 3. 主图模型和 token 网格

建议横轴固定为 N={1024,2304,4096,9216,16384}。
选择平方空间网格，避免用裁切 tensor 或改变长宽比来凑 2 的幂。
两模型使用相同 N，但头数与 d 不同；两子图分别展示，不将二者耗时差归因为视频属性。

| N | PixArt 图像像素 H×W | PixArt latent H×W | Wan 视频像素 H×W | Wan latent F×H×W |
| ---: | --- | --- | --- | --- |
| 1024 | 512×512 | 64×64 | 256×256 | 4×32×32 |
| 2304 | 768×768 | 96×96 | 384×384 | 4×48×48 |
| 4096 | 1024×1024 | 128×128 | 512×512 | 4×64×64 |
| 9216 | 1536×1536 | 192×192 | 768×768 | 4×96×96 |
| 16384 | 2048×2048 | 256×256 | 1024×1024 | 4×128×128 |

### 3.1 PixArt-Sigma：图像主模型

- 固定现有 PixArt-Sigma-XL-2-1024-MS 权重；16 heads，d=72，28 层。
- 空间 VAE stride=8，patch=2，N=(H_pixels/16)×(W_pixels/16)。
- 当前完整 pipeline 已存在；权重、配置、text encoder、scheduler 各自记录 SHA。
- 已有下载记录 revision=e102b3591cc82e97071b8b4cb90d834d0c487207。
- 使用同一 checkpoint 扫形状，以控制模型变化；512/768/1536/2048 不称为已验证的
  原生训练分辨率，也不把 2048² 对应的 16384 tokens 称为 4K 图像。

### 3.2 Wan2.1-T2V-1.3B：视频主模型提案

- 固定现有 transformer 权重；12 heads，d=128，30 层。
- 固定 13 个像素视频帧；VAE temporal stride=4，因此 latent frames=4。
- patch=(1,2,2)，N=4×(H_pixels/16)×(W_pixels/16)。
- 当前只下载 transformer。正式轨迹须补齐 text encoder/tokenizer/scheduler；
  完整生成质量还需 VAE。仅导出 latent 采样过程的 Q/K/V 时可不执行 VAE decode，
  但必须核实其 stride/scale 配置。不得用零文本 embedding 代替正式条件采样。
- 实际 ModelScope 权重 revision=cb9476dbf95a316400536c39ac72f6afaf45b704，
  config revision=9bfed53207fb3a90b49d32a462e07284f1419e82；以文件 SHA 为最终依据。
- 13 帧方形分辨率扫描是合法骨干形状，不等同于默认 480×832 视频生成配置。

### 3.3 DFoT-MCRAFT：d=64 补充

- 固定 256×256 像素、12 heads、d=64；每帧 256 patch tokens。
- 先使用真实 50 帧采样上下文 N=12800 作补充向量，另做 d=64 短功耗微基准。
- 骨干可接收 4/9/16/25/36/50 帧，对应 N=1024/2304/4096/6400/9216/12800。
  但现 noncausal sampler 的 horizon=max_tokens=50，会 padding 短请求；
  不将“请求 9 帧”写成真实 Attention 已变成 N=2304。
- 不扩到 64 帧凑 N=16384；若要多 N 的自然轨迹，先设计并验证 horizon 调整。

已有 Fig.1 的五点来自固定噪声级 Gaussian latent，Wan 使用零文本 embedding。
它们可继续作为明确标注的 profiling，但不能直接复用为本主图的自然采样轨迹向量。

## 4. 冻结测试向量

### 4.1 主图向量

建议统一 30 个 denoising steps，使用各模型配套 scheduler，并完整记录配置与实际
timestep 数组；不是把同一数值 t=500 强加给不同模型。pipeline 其余参数在采集前冻结。
PixArt 取零起始 layer=14，Wan 取 layer=15；取零起始 step=15。
性能 seed=301；完整采样可能用 CFG，导出固定 conditional branch 的 B=1 张量。
这是一分支的完整多头 SDPA，不称为整个双分支 CFG 调用或模型端到端。

固定提示词建议：

- PixArt：`A small cactus with a happy face in the Sahara desert.`
- Wan：`A red toy car moves slowly along a road in a sunlit park.`

Q/K/V 在 QK normalization/RoPE 完成后、SDPA 计算开始前截获。
每个 N 通过完整像素/latent 形状生成，不裁 d、不从长向量截 N、不平均多个头。
主图共 2 模型×5 长度=10 个完整多头硬件回放点；均须输出检查通过。

### 4.2 校准、数值和质量向量

- 校准与评估分离：校准 seeds=1001/1002，使用另两条提示词；不得取测试输出的
  最大值作为该测试点的 oracle OUT_SCALE。PixArt校准提示词为
  `A wooden cabin beside a lake at sunrise.` 与 `A yellow train in a green valley.`；
  Wan为 `A blue boat crosses a quiet lake.` 与 `A dog runs across a grassy field.`。
  校准先覆盖N=1024/16384，流式收集各层、各step的范围统计；不保存所有完整QKV。
- 数值评估 seeds=301/302/303，抽取 early/middle/late layers 和 steps。
  PixArt layer={0,14,27}，Wan layer={0,15,29}；step={0,15,29}。
- 先检查 N=1024 和 16384 的真实激活；其余 N 在数值资格通过后补齐。
  稠密参考按 query/KV tile 分块，不能创建全量 N×N golden 矩阵。
- 不要求每个抽样向量都做长 RTL 仿真；全部做离线 shadow/误差检查，主图 10 点和
  选定边界向量做 RTL 逐字节回放。记录哪些向量经过哪一层验证。
- 最小生成质量检查：PixArt 在 512²/1024²、3 提示词×3 seeds，原浮点与定点 Attention
  使用相同初始噪声、scheduler、steps。报告配对 LPIPS/PSNR、文本一致性及失败样本。
  三条提示词固定为主图cactus提示词、`A ceramic teapot on a wooden table.`、
  `A city street in the rain at night.`；seeds=301/302/303，每分辨率9对样本。
  每组9个样本只作配对 sanity check，不报告 FID 或宣称全面保持生成质量。
  Wan 完整 pipeline 可用后再按预算做配对视频检查，不以图像指标冒充视频质量。

### 4.3 当前硬件允许的量化方式

SCORE_SCALE 和 OUT_SCALE 是 START 时的 job 全局快照，自动多头循环中不能按 head 换值。
首选整个 [1,H,N,d] 的每个 Q/K/V tensor 使用全局对称 INT8 scale；按model/layer
汇总独立校准集的max-abs，除以127，得到跨head/N/step共用的参数，并冻结。
Q/K/V各自独立scale；评估输入clip到[-127,127]，记录实际clipping率。
OUT_SCALE同样来自校准集的浮点输出范围，不用当前测试的golden临时定标。
浮点score scale对应sQ×sK/sqrt(d)，但不能直接把该数作为SCORE_SCALE寄存器值。
当前PWL输入采用Q8单位，normalizer约生成32768×O/L，故寄存器有效因子应满足：

    m_score / 2^shift_score ≈ 256 × sQ × sK / sqrt(d)
    m_out / 2^shift_out ≈ sV / (32768 × sO)

依据现有整数参考逐步核验mantissa/shift可表示范围、舍入、截位和饱和；
保存理想因子、实际编码和相对编码误差，避免漏掉256或32768的单位转换。
如需 per-head scale，则必须拆成 H 个独立 job，计入每次 START/初始化/drain；
不能让一个多头 job 暗中使用不同 scale，或忽略这些开销。

分别测量三种误差：原始浮点与量化后浮点 SDPA 的差、定点算法相对量化后浮点的差、
RTL 相对定点参考的逐字节差。不能只报告第三项相等就宣称模型数值正确。

### 4.4 向量记录和存储

每点保存 model/config/weights SHA、revision、pipeline commit、prompt、seed、
layer/step/实际 timestep、CFG 分支、B/H/N/d、F/H/W、mask、dtype、QK norm/RoPE位置，
原始 tensor、INT8 tensor、scale、FP32/整数 golden 和所有文件 SHA。
原始/验证大向量保留13服务器；33只同步当前需要的 INT8 主图向量和微基准。
逻辑 tensor 存一份，loader 按需生成 feature-major 流；不在磁盘为每个 query tile
重复保存 K/V。每个 tensor/tile 发送 d 个 256-bit word，token 尾 lane 独立屏蔽。

## 5. 第一道放行：长 N 数值与溢出

当前 PV 直接累加 P16×V8，再取 INT32 低位，没有乘积前右移。
均匀权重 P=32767、V=-128、跨 tile 单位 alpha 的压力例中，N=513 即可能越过
INT32 范围；这不代表所有实际 N>512 都溢出，却证明合法 d 不等于长 N 已正确。
现 bit-accurate 参考也截断 INT32，因此 157 个短 UVM job 不能替代本检查。

正式性能前，使用 INT64/任意精度 shadow 检查每次 PV/O 更新截断前的范围、
online alpha 重缩放、L 累加、scale、输出饱和与输入量化裁剪。
同时记录PWL输入范围、P截零比例与行和误差，以区分量化、指数近似和O溢出。

硬性要求：RTL/整数参考一致、合法 mask/地址/WSTRB、无 X、无 O 溢出。
建议预审目标：每个head输出相对 L2 误差≤5%、cosine≥0.99，同时报告 MAE/RMSE 和饱和率；
相对L2定义为 ||O_dequant−O_FP32||₂ / max(||O_FP32||₂,1e−12)，另保留逐head最大误差。
这些是待确认的工程门槛，不是通用的模型质量保证。先用独立校准数据固定门槛和
scale，再做评估；失败点原样记录，不换 seed、删差点或事后放宽门槛。

如果真实长 N 未通过：暂停主图采集，先讨论位宽/缩放修正；需要修改 RTL 时重新
短验证、综合并绑定新 PPA。禁止继续用当前网表面积配改后算法的速度/误差。

## 6. 主图计时和绘图

### 6.1 主计时边界

| 平台 | 包含 | 排除 |
| --- | --- | --- |
| CPU | 内存中完整 [1,H,N,d] SDPA 的执行、输出就绪 | QKV/输出投影、RoPE、采样循环、打包与拷贝 |
| GPU | 显存中完整多头 SDPA；CUDA event 覆盖实际 kernel | 同上；不含 PCIe 拷贝和分配 |
| FLOPA | 接受 START 到最后 head 最后输出 burst 的 B 握手；含 loader、cache 等待、重复 KV 读、计算与 drain | reset、预先配置寄存器、离线量化/打包、人为尾部空闲 |

FLOPA 暂按 1.60 ns 换算。图例/图注写 RTL cycles at the synthesis target，
并披露输入/输出服务模型：默认无额外回压、128-bit 每周期最多一 beat，即每方向
端口上限 10 GB/s；不把该上限当实测 DDR 带宽，不声称模型包含真实 DRAM 时序。
测试 producer 仅在接口许可时供应数据，去掉短 UVM 为功能测试插入的人为等待。
额外记录核心活跃/等待、输入 byte 和输出 byte；不能从主耗时中随意扣除 KV 重载。
可另做一个固定带宽减半的敏感性点；该点属于片外服务分析，不是 P SRAM 流量。

CPU/GPU：独立 pilot 冻结线程/后端后，建议20次预热、3批×30次正式测量；
GPU 用 CUDA event，CPU 用同步 wall time。过长点可预先降低重复次数并记录，
不能只对慢基线使用冷启动。记录中位数与 IQR、系统占用和异常原因。
RTL 主图每点一份完整确定性回放，不伪造重复误差条；另验证所选输入数据变化
是否影响周期。GPU 保留完整 H 的并行能力，不按单头时间乘 H。

性能工作量：MAC_useful=2×B×H×Nq×Nk×d，OP=2×MAC_useful。
RTL PERF_MAC 含32×32尾槽，属于物理槽位计数；START不自动清零时取计数差值。
主图以 ms 为纵轴，不将 FP16 FLOPs 与 INT8 ops混成统一吞吐冠军。
真实采样中可另记录SDPA-only与root Attention模块时间；它们分开解释，
不将含投影的Fig.1占比直接当作FLOPA可替换比例或端到端加速上界。

### 6.2 执行时间与长点

先用 N=1024 全 H 的性能 bench 测实际仿真 walltime，再安排2304/4096及长点。
9216/16384仍是目标点；后台排队执行，绝不由小 N 按 N² 推算填图。
若 VCS 太慢，可评估独立的加速 RTL replay，但必须先与 VCS 在短/中 N 上
逐字节和握手周期一致；新工具不是默认已具备。未完成点标未测，不能画推算曲线。

### 6.3 一张主图

建议一张单栏图，左右两个子图：(a) PixArt-Sigma；(b) Wan2.1。
三条线固定 CPU、GPU、FLOPA；共享图例，Times New Roman，PDF嵌入字体。
横轴使用真实五个 N，纵轴 ms 采用对数刻度；不以曲线必须打败 GPU 为验收条件。
主图仅比较一分支完整多头算子，不用 Fig.1 含投影的模块占比直接推模型加速上界。

## 7. 主表：对象、侧重点和公开数据边界

建议对象固定为 H-FA-1-4、H-FA-4-4、FSA/SystolicAttention、ITA System 与 FLOPA。
前三种外部论文分别提供FlashAttention PPA、最接近的数据流和INT8系统参照。

| 对象 | 选择理由 | 已核实可列字段 | 必须标出的边界 |
| --- | --- | --- | --- |
| H-FA-1-4 | 同为硬件 FlashAttention，较小并行配置 | 28nm/500MHz，1.14mm²，0.22W；BF16 0.256 与 FIX16 0.910 分开列 | Table IV 的原始混合吞吐，不同精度不能相加后与 FLOPA 有用MAC吞吐排名 |
| H-FA-4-4 | 展示并行度/PPA取舍 | 28nm/500MHz，3.34mm²，0.62W；BF16 1.64 与 FIX16 5.84 分开列 | 4 query并行/4 KV块；Nmax1024；未单列可直接抄用的 SRAM 面积 |
| FSA | 最接近的阵列内融合和 overlap 架构 | 16nm/1.5GHz，128×128阵列，FP16/FP32；192KiB scratchpad+64KiB accum | 面积不含 SRAM/DMA；功耗NR；不自行组合未能对齐的面积/峰值条目 |
| ITA System | INT8、1024 MAC，提供含系统存储的参照 | 22nm/500MHz/0.8V，0.407mm²，67.8KB，121mW；原文吞吐1.02TOPS | 硬件支持QKV/输出projection；Table I吞吐非长N SDPA实测；不推断121mW窗口的具体阶段组成 |
| FLOPA | 本设计 | 当前总面积2.452364mm²、SRAM0.656747mm²、480宏、120KiB物理容量；目标625MHz | 新模型活动功耗/有效吞吐待测；60KiB是逻辑分配，不与120KiB混用 |

外部工作的原文方法：

- H-FA：28nm physical synthesis，PowerPro基于模型推理活动；KV SRAM用22nm CACTI/
  hwcomponents估计后，经DeepScale换算到28nm。不是实际28nm SRAM宏的同库回读。
- FSA：性能来自RTL模拟；主实验为单头d128、N=2048–16384。面积排除SRAM/DMA，
  没有公开功耗，故功耗/能效填NR。已存在阵列内局部性，不能说FLOPA独有P局部驻留。
- ITA：功耗来自post-layout gate simulation的synthetic switching与PrimeTime，
  TT/0.8V/25°C；ITA standalone与System不能交叉借用面积、功耗或存储项。

禁止：用NR作0；按工艺平方缩放排名；把物理/逻辑存储混成一列；把不同工作负载的
peak TOPS、有效 SDPA TOPS和混合浮点/定点吞吐做统一能效排行。
FSA 的已披露面积分项/峰值表项不在本计划中自行重构总量，必要时向作者核实。

### 7.1 主表建议布局

一张跨栏表，标题简短为 Comparison with attention accelerators。
A块列外部工作与FLOPA：工艺/实现阶段、精度/阵列、频率、总面积、存储范围、
功耗及方法、吞吐类型/工作负载。缺项填NR，脚注解释边界，不以长caption代替定义。
B块只放同条件消融：变体、总面积、P相关存储、每tile实际P读写byte、周期、
同一微基准能量。A/B各自比较，避免将两种证据当成同一统一排名。
H-FA Table IV未独立列出d，不能擅自将其PPA数字绑定到d=72或128。

## 8. 创新点对照：已获范围批准，按匹配设计实施

| 变体 | 改动 | 可支持的结论 | 当前状态 |
| --- | --- | --- | --- |
| F0 FLOPA | 当前局部P、持久O、重叠调度 | 基准实现 | 已有RTL/映射，实验待做 |
| F1 P-buffer PV | 共享P缓冲供应PV，移除被替代的PE概率寄存器；保持32×32 MAC预算和相同精度 | 在匹配资源/接口下比较数据流的流量、总面积、能量取舍 | 范围已批准，须独立RTL设计/验证/综合，不是现成开关 |
| F2 no-PV/row-update-overlap | P/O/cache/ICG不变，PV等softmax/row-state完成后再启动 | 隔离PV与row-state重叠的周期/能量影响 | 可优先实现的最小对照；不是全部阶段完全串行 |

F1是数据流对照，不是对某篇论文的完整复现；bank/端口/缓冲与延迟必须真实实现。
设计时允许为F1选择适配的PV/cache布局，不能故意强迫其使用低效布局；共同外部
带宽和逻辑tensor边界不变，必要转置/端口/适配成本必须计入。
如果PV映射随P存放位置改变，结论限定为整体数据流取舍，不单独归因为某个寄存器。
32×32×16-bit P tile的逻辑容量为2KiB，实际宏数量由端口、字宽、深度和bank决定。
必须计算移除的寄存器和新增的mux/控制/retiming，总面积都计入。
若只保留原PE概率寄存器、额外加scratchpad强制spill/reload，只能作为搬运代价
消融，不能据其新增SRAM宣称相对优化竞争架构的面积优势。

各变体固定相同QKV、scale、tile顺序、PWL、归一化/舍入、最大d、库、PVT、目标周期、
接口服务与输出检查。每个功耗变体用自己的匹配网表/DDC/活动，不能借F0功耗。
若某变体不满足共同频率，应如实报告，并另给共同可达时钟对比；不能只给慢变体低频。
门控/normalizer优化不顺带关闭，避免把它们的收益归于P驻留。

O持久化先报告宏面积与实际端口访问，不在无对照时编造独立能量节省百分比。
共享SFU也不能与假想的“每PE一套完整独立SFU”作虚弱对比，FSA复用MAC的事实须保留。

## 9. 主表功耗协议

### 9.1 短微基准与长主图分开

建议标准表征点 Nq=Nk=256、H=1、d=72，输入取PixArt主图N=4096向量的
head0、前256个Q/K/V。明确标为截短上下文 microbenchmark，不进入原形主图。
辅助点 d=64（MCRAFT）、d=128（Wan），同样N=256/H=1；主结论不依赖随机INT8输入。
每个d用对应的原始浮点张量切片；微基准scale只能来自独立校准seed的相同切片规则，
不能根据被测切片golden临时重定标。F0/F1/F2对同一测试输入使用完全相同的scale。
这些scale单独记录，不冒充完整MHA量化参数；功耗比较不能混入scale选择的变化。
先做N=32/H=1的门级流程pilot，再决定N=256预算。主点建议3个输入seed；
辅助d在预算不足时可只做一个seed并明确样本量。F1/F2先只测相同d=72主点。

PPA表征仅对该微基准报告功耗、周期、有效吞吐和能量。严禁用它的平均功耗
乘主图N=16384/全H耗时，或拼成所谓实测长模型TOPS/W。
若要发布原形模型能量，另做该原形完整job的活动回读/可审计能量估计并标方法。

### 9.2 功耗范围与公式

范围为attention_accel_top内全部标准单元、寄存器、ICG和实际实例化SRAM宏；
排除片外DRAM、PHY/封装/板卡、主机量化/打包和模型其他算子。未做CTS/布线时明确
为mapped pre-layout activity-based estimate，不能叫芯片实测或真实时钟树功耗。
单列P_dynamic、P_leakage、P_total与主要层级分量，SRAM和PE寄存器均不能漏计。

窗口与周期统一：成功START到最后输出B握手，包含job必要初始化、等待和drain；
排除预先reset/配置及人为前后空闲，不通过加入长idle稀释平均功耗。

    t = SAIF_active_duration = C_window × T_clock
    E_job = (P_dynamic + P_leakage) × t
    MAC_useful = 2 × H × Nq × Nk × d
    energy_per_MAC = E_job / MAC_useful
    effective_TOPS = (2 × MAC_useful) / t / 1e12

只有同一个job、同一窗口的P/C/MAC才计算能效；峰值TOPS另列，不能代替有效吞吐。
比较变体优先用energy/job与总面积，而非孤立的平均W或MHz。
CPU/GPU主图只比时间；本轮不将CPU package/GPU整卡功耗与ASIC IP功耗并排算节能倍数。

### 9.3 功耗流程前置与放行

现旧gate脚本强制clock_gating=none且拒绝dut层级探针，新runtime sequence尚未
实现SAIF窗口；因此必须先适配gate-safe bench、START/loader和SAIF开关，不能直接
运行旧入口或把内部探针路径硬套在mapped netlist上。

核验：UVM/输出、X、实际loader/AXI握手、SRAM冲突、ICG开关、SAIF时间和输入/输出hash；
核对原simv/网表/DDC/库/hash、目标时钟、SAIF标注覆盖和annotation conflict。
无未知黑盒/关键活动缺失才能放行；目标用户标注100%、冲突0，逐项解释达不到的对象。
SRAM Liberty已有internal/leakage及读写/休眠条件表征；不能因PWR-428就将全部SRAM
判成未表征黑盒，也不能以总标注100%代替逐宏power arc核验。
定位PWR-428对象，检查480宏的实际链接与power arc、28 ICG的活动传播。
当前默认活动率4.8406/5.2757W不进入新工作负载表，也不能与历史SAIF直接算节省率。

## 10. 输出字段与执行顺序

只使用两类结果：主图原形算子行；主表PPA/微基准/对照行。
主图最少字段：model/vector SHA、B/H/N/d、CPU线程/NUMA/GPU后端、各平台精度、
误差/overflow、C_START_to_last_B、输入/输出byte、服务模型、时钟、ms与统计重复数。
主表最少字段：design/commit、PVT、实现阶段、面积范围、物理存储、P驻留位置、
活动源/窗口、Pdyn/Pleak/Ptotal、C/MAC/能量、覆盖/冲突、公开来源和NR原因。
现有evaluation_data.xlsx的旧数值保留历史标签；确认方案后再将新字段映射到两张基础表，
待测结果留空，不预填理论预测值。

| 阶段 | 产出与进入下一步的条件 |
| --- | --- |
| D0 方案冻结 | 前三项已确认；本详细方案的长度、数值门槛和短功耗微基准边界经讨论冻结 |
| D1 数据/数值pilot | PixArt真实轨迹、最长N shadow、量化/误差和完整H回放可行；不通过先修正确性 |
| D2 主图 | 固定向量，先1024/2304/4096，再9216/16384；CPU/GPU计时可先独立完成 |
| D3 机制 | 经批准的F2优先，F1另做设计评审；功能等价通过后才综合 |
| D4 活动功耗 | gate-safe N32 pilot→N256主点→必要辅助d/seed，不启动全H长N门级大矩阵 |
| D5 图表与论文 | 只写完成且资格通过的数据，短caption/脚注，检查四页正文可读性 |

原形完整H的RTL周期、同条件对照和微基准活动功耗各自排期，不因一个长仿真阻塞其他
已获批准的独立任务；不同时占满所有GPU或启动未批准的RTL变体。
Evaluation目标约1页：一张跨栏表、一张单栏左右子图，以及setup、质量和机制结论的
必要文字。ISCAS正文最多4页，第5页仅参考文献，不把关键实验结果移到引用页。
完整日志可在工程保存，但关键误差、对照和统计边界必须在正文可见，不能假定审稿人
会读取项目README或额外材料。本轮不提前将未测结果写成完成时态。
主稿目前仍含旧d=64架构描述和旧PPA；新实验完成后需做最小事实校正并统一数据版本，
不能让正文称固定d64、主表却称同一实现覆盖d128。原架构图/文字的主体结构继续保留。

## 11. 已核查的一手来源

- 本工程：RTL优化计划、实施报告、runtime-d RTL/UVM文档、综合与clock_audit证据。
- 13服务器：results/flopa_fig1_20261016下三模型protocol、完整模型配置/采样代码与下载清单。
- [H-FA：§VI-C/VI-D、Table IV](https://arxiv.org/html/2511.00295)。
- [FSA：§6.1/6.3、Tables 1/4](https://arxiv.org/html/2507.11331)。
- [ITA：§III/§V-A、Table I](https://arxiv.org/html/2307.03493)。
- [ITA作者ISLPED幻灯片](https://pulp-platform.org/docs/islped2023/ITA_GamzeIslamoglu-1.pdf)。
- [PyTorch 2.9 SDPA接口与后端说明](https://docs.pytorch.org/docs/2.9/generated/torch.nn.functional.scaled_dot_product_attention.html)。
- [ISCAS 2027作者要求：4页正文及可选1页纯参考文献](https://epapers2.org/iscas2027/ESR/authorinfo1.php)。

文献按原文逐项核查；学术检索MCP未挂载，本次使用arXiv/作者材料和官方软件文档。
