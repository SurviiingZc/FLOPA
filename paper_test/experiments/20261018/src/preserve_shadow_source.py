"""Recover the initial shadow source and require its previously recorded SHA."""

import hashlib
import json
from pathlib import Path


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
current = Path('/home/zhangcheng/DiT-FA/scripts/fixed_point_shadow.py').read_text()
source = current.replace(
    'def shadow(q, k, v, score_register, out_register, query_indices=None, return_state=False,\n'
    '           probability_exp=None, alpha_exp=None):\n',
    'def shadow(q, k, v, score_register, out_register, query_indices=None):\n',
).replace('    probability_exp = pwl if probability_exp is None else probability_exp\n', '')
source = source.replace('    alpha_exp = pwl if alpha_exp is None else alpha_exp\n', '')
source = source.replace(
    '    final_acc = np.zeros((len(q), v.shape[1]), dtype=np.int64) if return_state else None\n'
    '    final_l = np.zeros(len(q), dtype=np.int64) if return_state else None\n', '',
).replace('alpha = alpha_exp(', 'alpha = pwl(').replace(
    'probability = probability_exp(', 'probability = pwl(')
source = source.replace(
    '        if return_state:\n'
    '            final_acc[row_start:row_start + len(queries)] = acc\n'
    '            final_l[row_start:row_start + len(queries)] = denominator\n'
    '    if return_state:\n'
    '        return output, stats, final_acc, final_l\n', '',
)
expected = json.loads((ROOT / 'pv_range_shadow.json').read_text())['source_sha256']
actual = hashlib.sha256(source.encode()).hexdigest()
assert actual == expected, (actual, expected)
(ROOT / 'qualification_shadow_source.py').write_text(source)
print('VERIFIED_QUALIFICATION_SHADOW_SOURCE', actual)
