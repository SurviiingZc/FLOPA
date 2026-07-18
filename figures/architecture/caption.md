**Fig. X | Fused OS-FSA FlashAttention accelerator architecture and PE-local dataflow.**
The 128-bit host interface fills 256-bit Q/K/V ping-pong cache words, each of
which exposes 32 INT8 lanes to the registered stream front end. Q rows enter the
32 x 32 output-stationary array from the left and K/V columns enter from the
top. During QK, column `c` finishes one cycle before column `c+1`; the QK tail
therefore launches a registered left-to-right row-maximum pass without a second
score scan. The updated row maximum returns right-to-left, and every PE locally
computes `score_reg - m_new`. Only the scale/PWL-exp operation uses a shared
32-lane pipeline outside the PE fabric. Its probabilities write back into
PE-local `prob_reg` registers, traverse a left-to-right row-sum chain to update
the row `(m,l,alpha)` state, and shift toward the PV boundary only with a valid V
word. The same PE array then accumulates probability-V products into local
INT32 `O_acc` registers. A reciprocal-based final normalizer and requantizer
produce the 128-bit AXI4 writeback stream. All inter-PE reduction and restream
links are fixed-width, registered, nearest-neighbor paths; no full score or
probability tile crosses a module boundary.

Recommended placement: IEEE two-column `figure*` at `\textwidth` (183 mm).
Use the PDF or SVG for publication and the 600 dpi TIFF/PNG for review or
raster-only submission systems.
