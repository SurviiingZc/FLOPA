"""Recover and hash-check the exact successful capture source before archiving."""

import hashlib
import json
from pathlib import Path


ROOT = Path('/10T/zhangcheng/flopa_evaluation_20261018')
SCRIPT = Path('/home/zhangcheng/DiT-FA/scripts/capture_trajectories.py')
current = SCRIPT.read_text()
pixart = current.replace(
    "        attentions = [module for name, module in self.transformer.named_modules()\n"
    "                      if name.endswith('.attn1')]\n"
    "        assert len(attentions) == (28 if self.model_name == 'pixart' else 30)\n"
    "        for index, attention in enumerate(attentions):\n",
    "        blocks = self.transformer.transformer_blocks\n"
    "        for index, block in enumerate(blocks):\n"
    "            attention = block.attn1\n",
).replace(
    '        def sdpa(query, key, value, *args, **kwargs):\n'
    '            result = original_sdpa(query, key, value, *args, **kwargs)\n',
    '        def sdpa(q, k, v, *args, **kwargs):\n'
    '            result = original_sdpa(q, k, v, *args, **kwargs)\n',
).replace("                self.process(query, key, value, result, 'BHND')\n",
          "                self.process(q, k, v, result, 'BHND')\n")
for model, source in [('pixart', pixart), ('wan', current)]:
    protocol = json.loads((ROOT / model / 'protocol.json').read_text())
    actual = hashlib.sha256(source.encode()).hexdigest()
    assert actual == protocol['script_sha256'], (model, actual, protocol['script_sha256'])
    (ROOT / model / 'capture_source.py').write_text(source)
    print('VERIFIED_CAPTURE_SOURCE', model, actual)
