# Runtime-d RTL/UVM 短序列验证

更新：2026-10-18。验证对象为同一 `MAX_D=128` 物理实例，ABI 版本 3。
本轮只做短序列功能验证；不把旧版 21/23 项或历史覆盖率算作新版结果。

## 入口与产物

```bash
RUNTIME_D_OUT_DIR="$PWD/tb/sim/build/runtime_d_current" make runtime-d-smoke
# 或等价入口
RUNTIME_D_OUT_DIR="$PWD/tb/sim/build/runtime_d_current" \
    bash tb/sim/scripts/run_uvm_regression.sh
```

仅编译一份 UVM `simv`，所有 d 和连续 job 复用它；另外有一份很小的算术
module 测试可执行文件。命令显式选用新输出目录，不覆盖历史验收证据。
脚本不指定目录时默认 `tb/sim/build/runtime_d`；本次实际保留了该原综合输入构建
以及 `tb/sim/build/runtime_d_formatted` 格式版构建。均不生成波形或 SAIF。
可用 `RUNTIME_D_TESTS` 选择单项调试。`RUNTIME_D_SKIP_COMPILE=1` 只有在源码、
ASIC SRAM 模型、VCS 路径和两份可执行文件的哈希均匹配时才允许复用。

* `compile_manifest.json`：固定源码清单、编译前后哈希、SRAM 模型、工具路径、
  两份可执行文件及编译日志哈希；编译中源码变化将导致失败。
* `summary.json` / `summary.txt`：每项 UVM 的结果、error/fatal、job、有效字节、
  逐 job 功能周期/访问次数，以及原始日志路径和哈希。
* `module_summary.json`：乘法器、normalizer、ICG 定向测试结果及日志哈希。

即使 VCS 返回 0，缺少 UVM 结束摘要、非零 error/fatal、少跑 job、断言失败或
缺失 module PASS 标记都判失败，脚本返回非零。

## 短测试矩阵

| 测试 | 检查内容 | 完成 job 数 |
| --- | --- | ---: |
| `fa_runtime_d_smoke_test` | 同实例 64→72→128→72→64；Nq=3/5、Nkv=5、两头 | 5 |
| `fa_runtime_d_range_test` | d=1..128 逐个运行；Nq=1、Nkv=3 | 128 |
| `fa_runtime_d_boundary_test` | d=64/72/128 × N=31/32/33/65 | 12 |
| `fa_runtime_d_multihead_test` | Nq=3、Nkv=5，64×12头、72×16头、128×12头 | 3 |
| `fa_runtime_d_control_test` | 非法 d、旧模式位、WSTRB、busy 配置/START、两种 reset | 3 |
| `fa_runtime_d_arith_test` | 原生三种 d，Nq=3/Nkv=33，PWL 边界及全范围随机 QKV | 6 |

所有数值 job 默认输出 AXI ready 有 50% 随机停顿，O base 为 `0xff0`，同时覆盖
4-KiB burst 边界。总计 157 个完成 job、66,312 个输出有效字节。拒绝的请求和
主动 reset 的未完成 job 单独检查副作用，不混入“完成 job”分母。

运行命令可通过 `fa_random_qkv_test` 的 `FA_HEAD_DIM/FA_HEADS/FA_SEQ_Q/FA_SEQ_KV/
FA_READY_LOW_PCT/FA_SCORE_SCALE/FA_OUT_SCALE/FA_O_BASE` plusargs 调整短调试输入。

## 独立参考与有效输出检查

参考模型使用完整实际 d 和所有头，各头 Q/K/V 通过确定的 INT8 变换形成不同数据。
参考保留逐 KV tile 的在线最大值、PWL 指数、旧 L/O 重缩放、定点截断/舍入/饱和，
不以一次全局 softmax 替代，也不裁剪 72/128 维。它从测试张量独立算 golden，
而非读取 DUT 的中间 P、O 或最终输出作为期望值。

scoreboard 同时检查 loader 实际握手字、每头每行每维输出、重复/缺失地址和 WSTRB。
物理 head stride 为 `align_up(Nq*d,16)`，只有每头末尾可有对齐空隙；任何写入该空隙
的有效 strobe 都报错。d=72 的跨行拼接、奇数 N 和多头由逐字节比较直接覆盖。
每个有效 job 在 START 后装载，故每次 d 切换都会穿过真实 cache 所有权清空路径。

## 实际动作计数与范围

`tb_top` 在 DUT 真实接口的根时钟 posedge 观察：

* loader `valid && ready`：已接受的 128-bit beat；不是 driver 提交数。
* `qk_array_valid_w` / `pv_array_valid_w`：每 KV tile 各发出 d 个 feature。
* `norm_rd_en_w`：每 Q tile 四个 stripe 各读 d 个 feature。
* `pv_complete_q`：实际完成 tile，用于短序列 producer 等待 bank 释放。

golden 独立推导总次数并严格比较；PV/normalizer 还断言 feature 不得达到或超过 d。
array/normalizer 的门控时钟另在其真实 posedge 计数，DONE 排空后观察其停止。
有效 MAC 为 `2*heads*Nq*Nkv*d` 的数学工作量；硬件 PERF_MAC 仍按物理 32×32
tile issue 计数，含尾 token 空槽，不将两者混用。

功能周期含寄存器编程、串行 producer 和 AXI 停顿；这些日志不是论文性能曲线。
本轮使用真实单口 ASIC SRAM 功能模型，关闭 notifier/specify 时间检查，是零延时
RTL 功能验证，不是门级时序签核、完整模型精度验证或长序列稳定性声明。

## 算术与门控 module 门槛

`tb_runtime_arithmetic` 使用独立 SV 乘法/64-bit 算术队列，检查：

* latency-3 32×31 signed multiplier：577 个精确乘积，含极值、拆分边界、
  正负组合、valid bubble 和中途异步 reset。
* normalizer：81 个八 lane 向量的值与 tag，含 II=1、bubble、负数舍入/饱和、
  门控关闭时 clear 和异步 reset 后恢复；这里固定 L=32768，其他在线 L 由 UVM 检查。
* ICG：idle 停钟、高相位改变 enable 不截断高脉冲、test-enable 打开时钟。

旧 module TB 含 B0 固定 d、causal/Decode 和旧 O 布局的历史假设，保留作参考；
不得以它们的历史 PASS 或覆盖率替代上述 ABI-v3 验收。
