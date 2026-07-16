# Flash Attention Accelerator

面向 AMD/Xilinx VCK190 / VC1902 的 FlashAttention-like attention accelerator 方案仓库。
当前仓库已经包含可综合 RTL、模块级回归和端到端数据流测试，采用 `VCS + DC`
先行、`Vivado/Vitis` 上板的开发路径。

## 当前目标

- 第一版实现 MHA，后续预留 GQA 扩展。
- 采用 INT8 GEMM + 定点在线 softmax 的混合精度路线。
- 主线架构为 32x32 OS 阵列、32 lane softmax、Q/K/V 同规格 banked SRAM tile cache。
- 面向 Re10K attention 子层做真实网络验证。

## 推荐工作流

1. 先读 `plan.md`，确认整体约束、里程碑和架构取舍。
2. 先在 `VCS` 做功能仿真和回归。
3. 再用 `DC` 做前端综合、可综合性和时序边界检查。
4. 最后迁移到 `Vivado/Vitis`，完成 VCK190 板级集成和上板。

## 仓库内容

- `plan.md`：主方案、架构、验证、性能和实现路线。
- `docs/pdf/flash_attention_hardware_papers.md`：论文整理与阅读顺序。

## Directory Layout

- `rtl/`: synthesizable RTL, grouped by `common/control/axi/compute/softmax/memory`.
- `tb/module_tb/`: lightweight module-level SystemVerilog testbenches for PE, softmax, cache, and AXI blocks.
- `tb/uvm/`: main UVM environment with env, agents, sequences, scoreboard, coverage, and reference model.
- `tb/uvm/ref_model/`: bit-accurate SystemVerilog reference model used by the scoreboard.
- `tb/sim/`: simulation entry points: filelists, scripts, vectors, and logs.
- `docs/pdf/`: papers and external references.
- `docs/`: project design document, verification document, and report data.
- `ppt/`: defense outline and presentation material.
- `asic/`: DC scripts, constraints, and synthesis entry points.
- `fpga/`: Vivado/Vitis project, constraints, and IP integration entry points.
- `tb/sim/build/`: generated simulation and lint outputs; not tracked.
- `asic/dc/work/`: DC work libraries and reports; not tracked.
- `asic/dc/logs/`: DC logs; not tracked.

## 可执行检查

```bash
cd tb/sim
make run          # 9 个模块/端到端 VCS 回归
make asic-sram    # 使用 /data/public SRAM 厂商模型验证宏拼接
make lint-rtl     # 纯 Verilog-2001 +lint=all

cd ../..
asic/scripts/run_rtl_check.sh  # 28nm TT-corner DC analyze/elaborate/link
```

ASIC 构建定义 `ATTN_ASIC`，Q/K/V 和输出 buffer 结构化实例化
`/data/public/SRAM/uhdsp_256x8m4s`。FPGA 构建不定义该宏，Q/K/V 推断 UltraRAM，
输出 buffer 推断 block RAM。DC 默认使用 `/data/public/STD/` 下的 28nm TT、0.9 V、25 C
标准单元库，并链接同条件 SRAM Liberty 生成的缓存 DB，用于典型面积和功耗评估。

## Reference Model Policy

The primary golden model should be written in SystemVerilog under `tb/uvm/ref_model/` so the UVM scoreboard can call it directly without DPI or Python runtime dependencies. Python is kept as an offline helper under `tb/sim/scripts/` for vector generation, Re10K sample extraction, and error analysis.

## Status

- 32x32 shared output-stationary array、32-lane online softmax、Q/K/V ping-pong cache、
  final normalization 和 AXI writeback 已接通。
- 第一版支持 MHA/prefill；GQA/decode 配置保留但启动时明确拒绝。
- 模块级与两块 K/V tile 的端到端定向回归已通过。
