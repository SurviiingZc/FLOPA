> 2026-10-19 执行更新：用户要求先完成本轮实验，再优化数值。旧数值门槛不再阻断工程性能/功耗/对照测试，误差与溢出统计仍保留。逐字节功能、协议、哈希和功耗活动窗口仍需核验。详见 PRECISION_DEFERRAL_20261019_ZH.md 与 experiments/20261018/LATEST_RUN_20261019_ZH.md。

# FLOPA：ISCAS 实验入口与计划

更新：2026-10-18。作者已要求按计划开始，当前进入D1数值检查和测试流程验证。
执行记录见 [本轮状态](experiments/20261018/STATUS_ZH.md)。

## 1. 本轮计划

详细方案见 [EVALUATION_PLAN_ZH.md](EVALUATION_PLAN_ZH.md)。它是后续 Evaluation 的主计划，
替代本 README 旧版的模型/单头实验建议；历史数据不能转作新 RTL 的实测结果。

作者已经确认：

- 主图：PixArt-Sigma + Wan2.1-T2V-1.3B；DFoT-MCRAFT 补充 d=64 验证。
- 单位：完整多头 SDPA，排除 QKV/输出投影和 RoPE；三平台使用相同来源的模型张量。
- 允许新增匹配对照并重新综合、回读活动功耗；保留 FLOPA F0 主版本。

建议冻结的五个 N 为 **1024、2304、4096、9216、16384**：

| N | PixArt 方图像素 | Wan 方图像素（固定13帧） |
| ---: | --- | --- |
| 1024 | 512×512 | 256×256 |
| 2304 | 768×768 | 384×384 |
| 4096 | 1024×1024 | 512×512 |
| 9216 | 1536×1536 | 768×768 |
| 16384 | 2048×2048 | 1024×1024 |

它们由完整输入形状生成，不裁 N、不裁 d；扩展分辨率的生成质量尚未验证。
建议主图 B=1 conditional branch，PixArt 全16头/d72，Wan全12头/d128。
现 Fig.1 是固定噪声级 Gaussian latent 的 profiling；主图另从真实采样轨迹导出 Q/K/V。
Wan 当前只有 transformer，需要补文本组件和scheduler；完整质量评价还需VAE。
MCRAFT 短请求会被现 sampler padding 到50帧，不将短请求长度当真实Attention N。

## 2. 最先做的资格检查

当前 PV/O 是 INT32，直接累加 P16×V8。均匀P/同号V压力例在约512 tokens后即可能
溢出；这不意味着所有长模型向量必然失败，但短 UVM 通过也不能证明 N=16384 正确。
先用真实最长 N 输入做 INT64/任意精度 shadow、逐head误差和饱和检查。
若失败，先讨论位宽/缩放修正并重新绑定实现和PPA，不能先画性能曲线再补正确性。

## 3. 图、表与机制实验

- 一张主图：左右两个模型子图，CPU/GPU/FLOPA完整多头SDPA延迟随N变化。
  CPU为13服务器双路Xeon Gold6133，GPU固定单张RTX A6000；FLOPA为实测RTL周期
  ×1.60ns综合目标，明确输入服务模型及非芯片实测边界。
- 一张跨栏主表：H-FA-1-4、H-FA-4-4、FSA、ITA System与FLOPA；列精度、实现阶段、
  工艺/时钟、面积/存储、功耗方法和吞吐类型。不同口径不做统一冠军排名。
- 同条件对照：F1为真正buffer-fed PV，移除被替代PE概率寄存器并计入全部适配成本；
  F2仅关闭PV/row-update重叠。具体匹配规则与验收见详细计划。
- 仅额外插入P scratchpad而保留原概率寄存器的spill/reload变体，不能用于证明
  相对优化竞争架构的总面积优势。P tile逻辑2KiB也不能当作实际宏面积节省。

## 4. 功耗口径

建议 N=256/H=1/d=72 的真实QKV截短微基准为主表表征点，d64/128作辅助。
先做N32门级流程pilot；每个功耗值与同一job、同一活动窗口的周期和有效MAC配对。
短功耗微基准不进入原形主图，不乘长N/全头耗时推算所谓模型实测能量。

功耗包含 attention_accel_top 内全部标准单元、ICG、寄存器和已实例化SRAM宏；
排除外部DRAM/PHY、板卡、主机、模型其他算子。mapped-SAIF、post-layout活动估计、
PowerPro+CACTI的文献值分别标注；CPU/GPU本轮只作延迟比较。
现旧gate入口不兼容真实ICG与新testbench探针/SAIF控制，需要先适配gate-safe流程。
默认活动率4.8406/5.2757W和旧d64 SAIF均不能填入新工作负载结果。

## 5. 当前硬件及已有验证

- 分支 `codex/diffusion-runtime-d`；实际映射输入 `fc9e921`，后续格式整理有等价证明。
- 同一MAX_D=128实例支持d=1–128；六类短UVM共157个job、66312字节，error/fatal均0。
- 总面积2.452364mm²，SRAM0.656747mm²/480宏/120KiB物理容量；28个显式ICG。
- 28nm TT/0.9V/25°C，目标1.60ns；setup无违例，hold与2条min-cap尚未物理收敛。
- 无新版模型活动功耗或完整模型性能数据；不能由当前数值预先承诺节能或Fmax提升。

实现与验证文档：

- [RTL_OPTIMIZATION_PLAN_ZH.md](RTL_OPTIMIZATION_PLAN_ZH.md)：实现/未完成范围。
- [IMPLEMENTATION_REPORT.md](IMPLEMENTATION_REPORT.md)：功能、综合、来源和边界。
- [runtime-d RTL](../docs/rtl_runtime_d.md)、[UVM](../docs/uvm_runtime_d.md)：ABI和短验证。
- [clock_audit](clock_audit/README.md)：DDC时钟覆盖核验，不代表hold/物理签核通过。

重新执行短验证时使用新目录，保留原综合输入构建及日志：

```bash
RUNTIME_D_OUT_DIR="$PWD/tb/sim/build/runtime_d_current" make runtime-d-smoke
```

本轮按详细计划的五个长度、数值门槛、主表对象和短功耗工作负载执行。
当前完成测试台短回放与压力边界检查；真实模型采集、门级pilot等状态见执行记录。
没有取得的新数据留空，不由比例缩放、理论周期或旧结果补齐。
