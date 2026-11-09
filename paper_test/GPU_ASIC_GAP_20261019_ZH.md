# 当前 GPU / FLOPA 延迟差距诊断

## 已测事实

N=1024，B=1，原生全部 head；输入来自指定层/步的真实采样轨迹。

| 模型 | GPU FP16 SDPA ms | FLOPA INT8 job ms | FLOPA/GPU | loader bytes |
| --- | ---: | ---: | ---: | ---: |
| PixArt H16/d72 | 0.143360 | 10.0932368 | 70.405 | 76,677,120 |
| Wan H12/d128 | 0.132096 | 10.7979552 | 81.743 | 102,236,160 |

来源：33服务器 experiments/20261018/jobs 下两个 n1024 的 result.csv/run.log；
13服务器 baselines/cuda/pixart_p512.json、wan_p256.json。

GPU 输入已驻留显存；ASIC 从 START 到最后输出 B，包含 loader 和 drain。
该边界差异需保留；不能由此认为消除 loader 后 ASIC 就能超过 GPU。
当前 INT8 数值精度仅诊断，不是与 FP16 等精度的结果。

## 可由当前结构直接计算的下限（不是额外实测）

- 32×32 阵列、每 PE 每周期一 MAC、625MHz 目标，计算上限为 0.64 TMAC/s。
- 以一 MAC=2 ops 计，上限为 1.28 TOPS。QK+PV 工作量为 4 H N² d ops。
- PixArt 的理想 QK+PV 下限为 3.7748736ms，实际有效阵列利用率约37.4%。
- Wan 的理想 QK+PV 下限为 5.0331648ms，实际有效阵列利用率约46.6%。
- 128-bit/cycle loader 在625MHz下最多10GB/s；仅已接受输入 beat 的传输下限，
  PixArt为7.667712ms，Wan为10.223616ms。它们分别是实际job时间的76.0%和94.7%。
- 上述比例不是互斥的阶段占比，计算与装载可重叠，不能与计算占比相加。
- loader_wait_cycles是producer遭遇反压的周期，不能解释成MAC空闲周期。

## 重复装载来源

当前每个 query tile 都重新传入全部 K/V；N1024包含32个 query tiles。
输入字节数为 H N d + 2 H N d ceil(N/32)，与两个CSV的计数完全一致。
PE内P驻留没有消除跨query tile的K/V重读。这是不同层次的数据复用问题。

## 后续决策与可支持的论文主张

1. 保留本轮结果作为当前版本基线，继续完成已启动的测试，不以推算替换实测。
2. 检查跨query tile K/V复用和loader供给能力；增加复用需同时核算SRAM/寄存器成本。
3. 若目标是绝对GPU延迟竞争，需要更多阵列/多head并行和配套带宽，不能只调频率。
4. F0/F1/F2用于确认P驻留和重叠的实际面积、流量、周期和能量收益。
5. 现有证据不支持“FLOPA比A6000更快”，也尚不支持“FLOPA更节能”。
   后者需要一致活动窗口、完整功耗边界和当前97.22%时钟功耗分组审查。
