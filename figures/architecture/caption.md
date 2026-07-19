**Fig. X | Final fused FlashAttention accelerator architecture and PE-local dataflow.**
The 128-bit host interface fills 256-bit Q/K/V ping-pong cache words, each of
which exposes 32 INT8 lanes to the registered stream front end. Q is issued as
row streams, K is issued in key-major order, and V is stored feature-major so
that one cache word supplies `V[0:31,d]` per WS-PV cycle. During the
output-stationary QK phase, column `c` finishes one cycle before column `c+1`;
the QK tail therefore launches a registered left-to-right row-maximum pass
without a second score scan. The updated maximum returns right-to-left, and
each PE locally computes `score - m_new`. Only scale and PWL-exp use a shared
32-lane nonlinear pipeline outside the PE fabric. The resulting probabilities
write back to PE-local `prob_q` by column. A right-to-left row-sum token follows
the probability-column wave, overlapping local subtraction, exp, and rowsum.
The completed row sums are captured before feeding the serialized
`(m,l,alpha)` update at one row per cycle.

During WS-PV, V reuses the registered K column path while the horizontal sum
link computes `sum + P*V`. For every non-first KV tile, two stripe-local
half-row buffers hold `alpha*O_old`. Buffer 0 shifts seeds for features 0--31;
buffer 1 shifts features 32--63 while buffer 0 collects results. All 64 V
features issue continuously with one final array drain. Completed row halves
return directly to the row-major INT32 O buffer, implementing
`O_j = alpha_j*O_(j-1) + P_j*V_j` without an additional feature-major O SRAM or
a final transpose. A reciprocal-based normalizer and requantizer produce the
128-bit AXI4 writeback stream. All inter-PE reduction and restream links are
fixed-width, registered, nearest-neighbor paths; no complete score or
probability tile crosses a module boundary.

Recommended placement: IEEE two-column `figure*` at `\textwidth` (183 mm).
Use the PDF or SVG for publication and the 600 dpi TIFF/PNG for review or
raster-only submission systems.
