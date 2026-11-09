"""Start the two dependent workers after the N4096 capture queue was submitted."""

import subprocess
from pathlib import Path


root = Path('/10T/zhangcheng/flopa_evaluation_20261018')
scripts = Path('/home/zhangcheng/DiT-FA/scripts')
python = '/home/zhangcheng/miniconda3/envs/dfot/bin/python'
for script, name in [('prepare_layerstep.py', 'export'), ('benchmark_layerstep.py', 'gpu')]:
    with (root / f'layerstep_n4096_{name}.log').open('ab') as log:
        process = subprocess.Popen(
            [python, '-u', str(scripts / script), '--n', '4096'],
            cwd=scripts, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True, close_fds=True,
        )
    print(name, process.pid)
