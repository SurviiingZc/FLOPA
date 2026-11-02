# 当前 FLOPA 定点精度与 PixArt 配对生成验证

日期：2026-10-24。仅新增测试与报告；不修改冻结 RTL、PPA、校准 scale 或原始向量。
本轮最高序列长度为 9,216，不恢复已取消的 16,384-token ASIC 测试。

## 1. 测试目的与算术绑定

- 区分“与整数参考逐字节一致”和“与浮点 Attention 接近”两个结论。
- 复现当前 INT8 Q/K/V、Q1.15 P/alpha、8 段线性指数、16 项倒数种子、提前移位、
  INT32 回绕、跨 KV tile 重缩放、舍入和 INT8 输出饱和。
- 新 Torch 模型仅加速软件仿真，不代表修改硬件或得到新的硬件性能。
- QK 使用禁用 TF32 的 FP32 整数点积；PV 用 FP64 精确求和再做 INT32 模加。
- 先以原 NumPy 模型、边界案例、原有整数文件及已完成 RTL 输出做逐字节核对。
- 不使用理想指数、32 段指数或 256 项倒数候选替代当前设计。

## 2. Attention 输出误差

- 两个模型：PixArt-Sigma（H=16、d=72）与 Wan2.1（H=12、d=128）。
- 主长度点：N=1,024 / 2,304 / 4,096 / 9,216；seed301、去噪步索引15、条件分支。
- 跨层覆盖：N=1,024 与 4,096，PixArt 全部28层、Wan全部30层。
- 共124个完整多头向量；覆盖全部 query、KV、head 和输出元素，不抽取少量 query。
- 参考：原始真实采样 Q/K/V 转 FP32 后计算 dense SDPA。
- 硬件输出先以冻结输出 scale 反量化，再与 FP32 参考比较；不报告整数码差冒充激活误差。
- 报告总误差 MAE、RMSE，并拆分输入量化误差和定点计算新增误差。
- 另存逐层、逐头相对L2、裁剪与饱和诊断；保留所有误差较大的层和head。
- 汇总 MAE 按元素数加权；RMSE 累计平方误差后再开方，不直接平均各head的RMSE。
- 既有 qualification 聚合与本次重新运行的 Torch 模型结果分别保存，明确来源。

## 3. PixArt 闭环生成质量

- 固定原生1024×1024像素（N=4,096）、30步DPM-Solver++、guidance=4.5。
- 每组 FP16 与 FLOPA 使用相同初始噪声、prompt、seed、权重、scheduler和VAE。
- FLOPA组替换全部28个self-attention层、全部30步，并覆盖CFG两个分支。
- cross-attention、投影、MLP、scheduler及VAE使用原模型。
- 使用冻结的逐层量化scale，不依据测试输出重新校准。
- 预先确定4组，不在看到图像后删除或更换失败样例：

| 组 | 提示词 | seed |
|---|---|---:|
| 1 | A small cactus with a happy face in the Sahara desert. | 301 |
| 2 | A small cactus with a happy face in the Sahara desert. | 302 |
| 3 | A wooden cabin beside a lake at sunrise. | 301 |
| 4 | A yellow train in a green valley. | 303 |

组3、4的提示词曾用于独立scale校准，但使用不同seed；本测试不作为完全独立的泛化评估。
每组保存FP16/FLOPA图像、初始和最终latent、全部840次Attention调用的裁剪/饱和记录。
报告配对图像PSNR、SSIM和像素MAE/RMSE，以及最终latent MAE/RMSE。
这些指标说明相同噪声条件下的输出保真度，不能当作FID或大样本生成质量结论。

## 4. 当前清单

- [x] 汇总并验证既有124组qualification、原始张量、冻结scale与整数文件哈希。
- [x] Torch边界/尾tile核验；124组软件字节匹配，101个RTL作业另有审计。
- [x] 124组向量全部query/head重新计算，MAE/RMSE及逐层诊断已保存。
- [x] 四组原生1024/N4096配对生成和独立核验；不宣称总体质量无损。
- [x] 汇总表、全部4对图及两分表Excel审核副本已完成。
- [x] 已提供Table I两行和英文候选；正式论文/Excel仍待作者确认。

## 5. 文件与发布原则

- `existing_accuracy_aggregate.*`：对既有资格测试的重新聚合，不是新的模型运行。
- `accuracy/`：本次新Torch输出、FP32参考及逐向量/汇总误差。
- `quality/`：4组闭环生成与配对质量记录。
- 所有输出绑定软件SHA、原始张量SHA、冻结校准SHA；不覆盖旧实验结果。
- 当前正式论文与Excel由作者审核修改；本轮先提供可核对的新结果及候选改法。

## 6. 已完成结果与基线修正

4K全部层、step15条件分支，误差单位为反量化后激活值：

| 模型 | 层数 | MAE | RMSE |
|---|---:|---:|---:|
| PixArt-Sigma | 28 | 0.02793 | 0.03689 |
| Wan2.1 | 30 | 0.01750 | 0.02409 |

软件124/124完整输出匹配冻结o.bin，不能等同于124个RTL作业均完成。
rtl_equivalence_audit.json核对101个完整RTL作业、305823744输出字节。

原512像素4对计算完成且指标可复算，但FP16基线有栅格失真。
官方同checkpoint、同prompt/scheduler在原生1024像素下正常。
同latent的FP16/FP32 VAE解码PSNR约57dB，解码dtype不足以解释失真。
因此旧512批次仅保留异常诊断；新质量测试改为1024像素/N4096，
继续使用相同4组prompt/seed、30步和冻结scale，不覆盖旧结果。

## 7. 原生1024四组最终结果

四组均完成28层×30步、16个head、CFG两个分支；初始噪声相同，scale及数值算术未改。
独立核验PNG、latent、调用覆盖、冻结SHA及PSNR/SSIM重算，全部一致。

| 样例 | PSNR(dB) | SSIM |
|---|---:|---:|
| cactus 301 | 17.3406 | 0.765689 |
| cactus 302 | 16.4166 | 0.722734 |
| cabin 301 | 16.5829 | 0.539264 |
| train 303 | 17.8060 | 0.564974 |
| 四组算术均值 | 17.0365 | 0.648165 |

FP16原生基线视觉正常。两版本保留提示词主体，构图、纹理、反射等细节有可见差异。
这些是4对配对保真指标，不是FID或总体生成质量评估，也不支持“近无损”结论。
完成日期2026-10-25；仅补充软件数值实验，不产生新的ASIC速度或PPA结果。
正式文章和主Excel保持原样；候选文件待作者审核后再发布。
