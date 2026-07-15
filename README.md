# Flash Attention Accelerator

面向 AMD/Xilinx VCK190 / VC1902 的 FlashAttention-like attention accelerator 方案仓库。
当前仓库以方案、论文整理和后续 RTL 规划为主，推荐采用 `VCS + DC` 先行、`Vivado/Vitis`
上板的开发路径。

## 当前目标

- 第一版实现 MHA，后续预留 GQA 扩展。
- 采用 INT8 GEMM + FP-like softmax 的混合精度路线。
- 主线架构为 32x32 OS 阵列、32 lane softmax、Q/K/V 同规格 banked SRAM tile cache。
- 面向 Re10K attention 子层做真实网络验证。

## 推荐工作流

1. 先读 `plan.md`，确认整体约束、里程碑和架构取舍。
2. 先在 `VCS` 做功能仿真和回归。
3. 再用 `DC` 做前端综合、可综合性和时序边界检查。
4. 最后迁移到 `Vivado/Vitis`，完成 VCK190 板级集成和上板。

## 仓库内容

- `plan.md`：主方案、架构、验证、性能和实现路线。
- `doc/flash_attention_hardware_papers.md`：论文整理与阅读顺序。
- `doc/*.pdf`：相关论文 PDF。

## Directory Layout

- `rtl/`: synthesizable RTL, grouped by `common/control/axi/compute/softmax/memory`.
- `tb/module_tb/`: lightweight module-level SystemVerilog testbenches for PE, softmax, cache, and AXI blocks.
- `tb/uvm/`: main UVM environment with env, agents, sequences, scoreboard, coverage, and reference model.
- `tb/uvm/ref_model/`: bit-accurate SystemVerilog reference model used by the scoreboard.
- `tb/sim/`: simulation entry points: filelists, scripts, vectors, and logs.
- `doc/`: papers and external references.
- `docs/`: project design document, verification document, and report data.
- `ppt/`: defense outline and presentation material.
- `asic/`: DC scripts, constraints, and synthesis entry points.
- `fpga/`: Vivado/Vitis project, constraints, and IP integration entry points.
- `build/`: generated simulation, synthesis, and implementation outputs; not tracked.

## Reference Model Policy

The primary golden model should be written in SystemVerilog under `tb/uvm/ref_model/` so the UVM scoreboard can call it directly without DPI or Python runtime dependencies. Python is kept as an offline helper under `tb/sim/scripts/` for vector generation, Re10K sample extraction, and error analysis.

## Status

- Architecture plan and paper references are organized.
- RTL, verification, simulation, ASIC, FPGA, and deliverable-document skeletons are in place.
