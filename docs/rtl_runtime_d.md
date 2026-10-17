# 运行时 head dimension 的扩散 Attention 实现

日期：2026-10-17。分支：`codex/diffusion-runtime-d`。旧基线：`4e84950`。
本文件描述当前 RTL 候选实现；功能测试、综合面积和时序须以对应报告为准。

## 容量与 job 合约

- 顶层 `MAX_D=128`；兼容参数 `HEAD_DIM=MAX_D` 是物理最大容量，绝非活动维度。
- 活动 `d` 是 8 bit，允许 1..128；feature 地址为 7 bit，允许 0..127。
- AXI-Lite 0x050 (`HEAD_DIM`) 是可编程 shadow；合法 START 原子复制到 `cfg_head_dim_o`。
- busy 时 shadow 写有效，只用于下一 job；busy START 返回 SLVERR，不发 start 脉冲，
  当前 job 继续。非法 d、零序列长度、零头数的 START 返回 SLVERR，不访存/计算。
- `0x090 MAX_D` 是只读能力，值128；tile Q/K 0x054/0x058只读32。
- `0x048 NUM_Q_HEADS` 是唯一 MHA 头数。旧 `NUM_KV_HEADS`、MODE、O_STRIDE、
  QKV 基址/stride、VALUE_SCALE、MASK_CFG 地址保留为 RAZ/WI，无重复寄存器状态。
- CONTROL 仅 bit0 START、bit1 SOFT_RESET、bit2 CLEAR_DONE、bit3 CLEAR_ERROR有效。
  带WSTRB使能的bit4..31非零则整次CONTROL写返回SLVERR/BAD_CFG且不发命令；
  原mode/causal/prefill/decode控制不可静默执行dense算子。无Decode或三角因果掩码电路。
- PERF_CTRL保留实时写例外，便于运行中读清计数；其他工作负载字段均shadow/snapshot。
- VERSION 为 `0x00030000`。O 基址须16字节对齐且适配32bit AXI地址空间。
- SCORE_SCALE、OUT_SCALE也按 job锁存，由软件依据实际 d 和量化尺度计算；
  RTL未引入运行时开方/除法，也没有截断72维或补算满128维。

## Loader 与输出布局

START清除 cache ownership、pending半beat和在途memory valid；先 START，再装载新 job。
Q/K/V继续 feature-major：一个feature word含32个INT8 token lane。
每tensor/tile只传d个256bit word，恰好2d个128bit loader beat。
无效尾token lane另行掩码；无效feature地址不会请求或输出。

O外部输出为紧凑 row-major INT8：

```
head h base = O_BASE + h * align_up(Nq * d, 16)
tile q base = head h base + (q * 32) * d
row r      = d个有效byte，不含内部128-byte物理槽填充
```

完整32-row tile起点天然16字节对齐。尾tile发送 `valid_rows*d` 字节；
AXI master接收output buffer的真实WSTRB，末beat只写有效byte。
只有head末尾的对齐空隙不属于输出张量；不能用裸连续buffer误读为空间/特征数据。

输出buffer物理容量仍是32行×4个32byte组，每行预留128byte。
归一化每组产生8行；末组按实际有效feature数移到低byte并零填充。
读取采用48byte reservoir，追加每个物理word中的有效byte，跨行拼接成16byte beat。
内部padding从不输出。REQ/WAIT/APPEND/EMIT串行状态使数据在AXI stall期间稳定；
每32byte物理word有取数/追加控制开销，小d可能增加拼接成本，不宣称零开销。

## O SRAM：以版本分离端口

原始32-feature分组方案对d128需要4组，每row16个256x8宏，合计512宏。
候选改为每row两个完整128-feature版本，每个版本4个256x8宏：

```
KV pass j:    version old --同步读--> rescale --PE PV--> 同步写 version new
KV pass j+1:  交换两个版本的角色
最终norm:     只读取最后完成的 new 版本
```

首KV pass固定write_bank=0，seed为零；后续pass在pv_start切换write_bank。
控制器须先观察上一pass最末row/feature的PV drain完成；切换时不允许任何读/写。
普通seed读取 `!write_bank`，norm读取 `write_bank`，因此旧读/新写永不争用单口。
每个query/head首tile通过clear和first_pass重新建立所有权，不清空整个SRAM。
附带assertion检查pass切换及同版本同时读写；最终版本正确性由数值scoreboard验证。

物理容量/宏数推导：

| 存储 | MAX_D128逻辑容量 | 256x8宏数 | 物理容量 |
| --- | ---:| ---:| ---:|
| QKV双缓冲 | 24KiB | 192 | 48KiB |
| O双版本 | 32KiB | 256 | 64KiB |
| 输出buffer | 4KiB | 32 | 8KiB |
| 合计 | 60KiB | 480 | 120KiB |

双版本O的逻辑容量为32KiB，不能将单版本16KiB当作全部存储。
此处为RTL组织推导；最终实际宏数/面积必须由elaboration与mapped报告核实。

## ICG 与算术流水

- `fa_clock_gate` 在SYNTHESIS下实例化工艺 `CKLNQD1BWP12T30P140`，
  `.CP(clk), .E(enable), .TE(test_enable), .Q(gated_clk)`。
- RTL模型使用低电平透明锁存enable再生成gated clock，禁止组合enable直接AND时钟。
- 原22个边界：array控制与三个skew、每stripe PE/control/O/seed四支路、normalizer、
  output。新增六个QKV物理memory边界，预期28个ICG，实际数量以mapped报告为准。
- QKV门控覆盖输入wr/rd请求、寄存wr/rd请求和rd_valid尾部，保证最后valid可降零。
- stripe PE门控保留波前排空计数，O包含pass_start/读返回/写回，seed包含乘法valid。
- normalizer与output在全部drain、flush、stream/AXI stall期间保持必要时钟。
- PE共享乘法器已有token isolation。SFU输入寄存保留valid-qualified更新；
  normalizer O/scale/tag输入三级改为valid-qualified，避免无效输入翻转。

normalizer reciprocal乘法从32×31宽乘拆成两个32×16块，每块再拆A为16bit部分积，
共四个较小部分乘法；新增一级精确合并寄存，乘法latency=3、II=1。
O/scale/tag路径同步增加一级metadata，normalizer总延迟比基线增加1周期。
所有乘积位保留，无数值截位或PWL变化。新增soft-reset/job-start flush清除所有valid。
此举缩短宽部分乘法的组合跨度，真实频率收益需新综合证明。

既有PE→O SRAM hold路径不能靠增加一个寄存器就声称解决；新macro/ICG映射后必须
重新检查setup/hold，由综合hold修复和真实报告判断，不能以false path掩盖。

## 统计与验收

QK/PV/归一化均只请求实际d；d128次数使用8bit不回卷，tag7bit不超过127。
现有PERF_MAC统计物理发射槽：1024×(QK issue+PV issue)，包含尾token空槽。
有用MAC另由 `2 * Nq * Nkv * d * heads` 计算并与probe区分，不冒充物理利用率。

功能验收包含原生d与连续切换、d1..128小N、tail与跨KV/多head、随机AXI backpressure、
非法配置、busy shadow/重复START、soft reset、ICG排空和单口冲突。
验证通过后由根agent冻结版本再综合；旧d64结果不按频率/维度比例充当新版PPA。
