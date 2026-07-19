**Fig. X | Implemented tile-level pipeline of the fused FlashAttention accelerator.**
For an array with `R` rows and `C` columns and head dimension `H`, QK issues
`H` inner-product operands and drains through a registered `R x C` wavefront.
The left-to-right row-maximum pass starts from each column's staggered final QK
result and overlaps the QK tail. The updated maximum then moves right-to-left.
All rows of one column complete `Score-m_new` together, so the 32 shared exp
lanes map to rows and accept columns in order `C-1,...,0`. A seven-stage column
tag returns each probability vector to the same PE column. One cycle after the
rightmost column writes `prob_q`, a right-to-left rowsum token follows the
probability wave. Reverse subtraction, P-exp, and rowsum therefore overlap as
one column pipeline. All row sums finish together, are captured in 1 Kbit of
state, and assert `softmax_pv_ready_o`. WS-PV starts at that boundary while the
single row-state multiplier updates `l` over `R` cycles. The separate
`softmax_done_o` event protects the next tile and final normalization until all
row-state writes have committed. `L_SE=7` is pipeline latency, comprising the
four-cycle scale path and the three-cycle PWL-exp path; its initiation interval
remains one 32-row column per cycle.

During WS-PV, `P` remains in PE-local `prob_q` for one continuous 64-feature
stream. Two 32-entry buffers per active row hold the two `alpha*O_old` halves.
Buffer 0 shifts seeds during features 0--31; buffer 1 shifts seeds during
features 32--63 while buffer 0 collects results. The array issues 64
feature-major `V[:,d]` vectors without stopping at feature 31, then performs
one registered `C+R-1` drain. Completed row halves still write the unchanged
row-major output SRAM. The final normalizer and AXI writeback run only after
the last KV tile. Timeline widths are schematic; labels show dominant datapath
cycles and omit one-cycle controller handshakes and cache backpressure.
