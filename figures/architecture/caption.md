**Fig. X | Fused FlashAttention accelerator with PE-stationary probability and persistent O banks.**
The AXI4-Lite control plane and 128-bit tile loader fill parameterized 256-bit
Q/K/V ping-pong caches, each exposing 32 native INT8 lanes. Q and K drive the
registered 32x32 fused systolic array for output-stationary QK accumulation.
Staggered score completion launches the PE-local left-to-right row-maximum
pass; `m_new` returns right-to-left and overwrites `accum_q` with
`score-m_new`. A two-stage stripe-local gather feeds the shared 32-lane
scale/PWL-exp pipeline. Its scale and PWL stages have latencies five and three,
respectively, while retaining II=1. Tagged probability returns to the source PE
column, and the reverse rowsum wave follows it so SUB, exp, and rowsum overlap.
Captured row sums update `(m,l,alpha)` at one row per cycle through a two-cycle
multiplier while WS-PV begins from the earlier probability-ready event.

During WS-PV, `prob_q` remains stationary, feature-major `V[:,d]` reuses the K
vertical links, and horizontal row links compute `seed + P*V`. Each stripe owns
persistent row-banked INT32 O storage addressed by full feature ID. For a
non-first KV tile, `O_old[:,d]` is synchronously read and multiplied by row
`alpha` through a three-cycle seed path; the two-cycle V-cache response is
delayed to the same feature tag. There is no row preload or shifting O buffer.
The right-edge result writes `O_new[row,d]` directly to its row bank. Feature
groups `g0/g1` are independent single-port physical banks, not serial compute
halves. After the last KV tile, an eight-lane, seven-cycle normalizer scans one
stripe and feature per cycle. Each 32-feature group is followed by an eight-row
flush into 256-bit output entries for 128-bit AXI4 writeback. The same datapath
supports tiled prefill and single-query MHA decode. Each PE shares one exact
17x9 multiplier between QK and WS-PV, while its 33-bit adder is reused by QK,
rowsum, and WS-PV. Hierarchical ASIC clock gating uses one control/exp branch and one
branch per eight-row stripe; FPGA builds retain clock enables.

Recommended placement: IEEE two-column `figure*` at `\textwidth` (183 mm).
Use PDF/SVG for publication and the 600 dpi TIFF/PNG for review.
