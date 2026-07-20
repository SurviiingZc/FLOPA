**Fig. X | Fused FlashAttention accelerator with PE-stationary probability and persistent O banks.**
The 128-bit host interface fills parameterized 256-bit Q/K/V ping-pong caches,
each exposing 32 INT8 lanes. Q and K drive the registered 32x32 fused systolic
array for output-stationary QK accumulation. Staggered score completion launches
the PE-local left-to-right row-maximum pass; `m_new` returns right-to-left and
overwrites `accum_q` with `score-m_new`. A shared 32-lane scale/PWL-exp pipeline
accepts one completed score column per cycle and writes probability back to the
tagged PE column. The reverse rowsum wave follows probability writeback, so SUB,
exp, and rowsum overlap. Captured row sums update `(m,l,alpha)` serially while
WS-PV begins from the earlier probability-ready event.

During WS-PV, `prob_q` remains stationary, feature-major `V[:,d]` reuses the K
vertical links, and horizontal row links compute `seed + P*V`. Each stripe owns
persistent row-banked INT32 O storage addressed by full feature ID. For a
non-first KV tile, `O_old[:,d]` is synchronously read and multiplied by row
`alpha` just in time for feature `d`; there is no row preload or shifting O
buffer. The right-edge result carries the same feature tag and writes
`O_new[row,d]` directly to its row bank. Feature groups `g0/g1` are independent
single-port physical banks, not serial compute halves. After the last KV tile,
an eight-lane normalizer scans one stripe and feature per cycle; local pack
registers form 256-bit row/group words for 128-bit AXI4 writeback. The PE uses
one phase-selected multiplier for QK and WS-PV, and all array links remain
registered nearest-neighbor paths.

Recommended placement: IEEE two-column `figure*` at `\textwidth` (183 mm).
Use PDF/SVG for publication and the 600 dpi TIFF/PNG for review.
