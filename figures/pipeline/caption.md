**Fig. X | Tile pipeline with column-overlapped online softmax and preload-free persistent-O WS-PV.**
For an `R x C` array and head dimension `H`, QK issues `H` products and drains
through the registered wavefront. Staggered QK completion overlaps the
left-to-right row-maximum pass with the QK tail. The reverse `m_new` wave makes
all rows of one column complete `score-m_new` together. A two-stage
stripe-local gather bounds the selection network. The 32 scale/exp lanes then
accept one column vector per cycle; their five-cycle scale and three-cycle PWL
stages return a tagged probability vector to the same PE column. A reverse
rowsum token trails this writeback, so SUB, exp, and rowsum form one column
pipeline. Probability-ready starts WS-PV while the single II=1 row-state
multiplier issues `R` serialized `l` updates and drains for two cycles.

WS-PV issues all `H=64` feature-major V vectors continuously. On later KV
tiles, persistent O banks synchronously read `O_old[:,d]` at the same initiation
interval. One operand register plus a two-cycle rescale pipeline produces the
left-edge seed in three cycles; the two-cycle V-cache response receives one
alignment stage so payload and full feature tag enter together. The first tile
selects zero. After this fill, one feature is issued per cycle. The right edge
propagates `d` with every result and writes `O_new[row,d]` directly to the
addressed row bank. Consequently, neither the 32 rows nor the two feature
groups require a preload phase; `g0/g1` only denote physical single-port SRAM
groups. Non-final KV tiles immediately repeat QK/softmax and WS-PV with
`(m,l,O)` retained in place. After the last tile, eight stripe/group scans each
issue 32 features through the seven-cycle eight-lane normalizer, then flush
eight row words into 256-bit output entries before 128-bit AXI writeback.
Timeline widths are schematic and omit single-cycle controller handshakes and
external-memory backpressure.
