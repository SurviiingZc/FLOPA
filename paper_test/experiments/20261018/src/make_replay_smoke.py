"""Generate deterministic compact synthetic inputs for bench qualification only."""

import json
from pathlib import Path

import numpy as np

from fixed_point_shadow import shadow


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018/replay_smoke')
rng = np.random.default_rng(301)
for dim, nq, nk, heads in [
        (64, 3, 5, 2), (72, 33, 65, 2), (128, 31, 32, 2), (72, 32, 32, 1)]:
    folder = ROOT / f'd{dim}_q{nq}_kv{nk}_h{heads}'
    folder.mkdir(parents=True, exist_ok=True)
    tensors = [rng.integers(-32, 33, size=shape, dtype=np.int8) for shape in
               [(heads, nq, dim), (heads, nk, dim), (heads, nk, dim)]]
    results, stats = [], []
    for head in range(heads):
        output, report = shadow(*[tensor[head] for tensor in tensors], 0x00080001, 0x000f0001)
        results.append(output)
        stats.append(report)
    for name, tensor in zip(('q', 'k', 'v'), tensors):
        tensor.tofile(folder / (name + '.bin'))
    np.stack(results).tofile(folder / 'o.bin')
    (folder / 'manifest.json').write_text(json.dumps({
        'role': 'synthetic bench qualification only', 'd': dim, 'nq': nq, 'nkv': nk,
        'heads': heads, 'score_scale': '00080001', 'out_scale': '000f0001',
        'shadow': stats,
    }, indent=2) + '\n')
    print(folder, flush=True)
