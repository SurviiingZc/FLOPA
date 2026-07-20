**Fig. X | Tile pipeline with column-overlapped online softmax and preload-free persistent-O WS-PV.**
For an `R x C` array and head dimension `H`, QK issues `H` products and drains
through the registered wavefront. Staggered QK completion overlaps the
left-to-right row-maximum pass with the QK tail. The reverse `m_new` wave makes
all rows of one column complete `score-m_new` together. The 32 exp lanes then
accept one row vector per cycle, and a tagged probability vector returns to the
same PE column. A reverse rowsum token trails this writeback; SUB, exp, and
rowsum therefore form one column pipeline. Probability-ready starts WS-PV while
the single row-state multiplier completes the `R` serialized `l` updates.

WS-PV issues all `H=64` feature-major V vectors continuously. On later KV
tiles, persistent O banks read `O_old[:,d]` at the same initiation interval and
the alpha-rescaled value becomes the left-edge seed for feature `d`; the first
tile selects zero. The right edge propagates `d` with every result and writes
`O_new[row,d]` directly to the addressed row bank. Consequently, neither the
32 rows nor the two feature groups require a preload phase. `g0/g1` only denote
physical single-port SRAM groups. Non-final KV tiles immediately repeat the
QK/softmax and WS-PV pipeline with `(m,l,O)` retained in place. After the last
tile, four stripe-by-feature scans feed the eight-lane normalizer, and eight
row words per feature group are packed into 256-bit output SRAM entries before
AXI writeback. Timeline widths are schematic and omit single-cycle controller
handshakes and external-memory backpressure.
