"""Measure gross board energy per resident full-head SDPA over long windows."""

import argparse
import ctypes
import json
import os
import statistics
import subprocess
import threading
import time
from pathlib import Path

import torch
import torch.nn.functional as functional
from torch.nn.attention import SDPBackend, sdpa_kernel

from capture_trajectories import sha, write_json


class Nvml:
    def __init__(self, uuid):
        self.lib = ctypes.CDLL('libnvidia-ml.so.1')
        self.lib.nvmlDeviceGetHandleByUUID.argtypes = [
            ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p),
        ]
        self.lib.nvmlDeviceGetTotalEnergyConsumption.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulonglong),
        ]
        self.lib.nvmlDeviceGetPowerUsage.argtypes = [
            ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint),
        ]
        self.check(self.lib.nvmlInit_v2())
        self.handle = ctypes.c_void_p()
        self.check(self.lib.nvmlDeviceGetHandleByUUID(
            uuid.encode(), ctypes.byref(self.handle)))

    @staticmethod
    def check(code):
        if code != 0:
            raise RuntimeError('NVML return code: ' + str(code))

    def energy(self):
        value = ctypes.c_ulonglong()
        self.check(self.lib.nvmlDeviceGetTotalEnergyConsumption(
            self.handle, ctypes.byref(value)))
        return value.value

    def power(self):
        value = ctypes.c_uint()
        self.check(self.lib.nvmlDeviceGetPowerUsage(self.handle, ctypes.byref(value)))
        return value.value / 1000


def require_exclusive(uuid):
    raw = subprocess.check_output([
        'nvidia-smi', '--query-compute-apps=gpu_uuid,pid,used_memory',
        '--format=csv,noheader,nounits',
    ], text=True)
    for line in raw.splitlines():
        device, pid, memory = [field.strip() for field in line.split(',')]
        if device == uuid and int(pid) != os.getpid():
            raise RuntimeError('Energy window has another compute process: ' + line)


def telemetry(uuid):
    fields = 'uuid,power.draw,clocks.sm,clocks.mem,temperature.gpu,pstate,power.limit'
    return subprocess.check_output([
        'nvidia-smi', '-i', uuid, '--query-gpu=' + fields, '--format=csv,noheader',
    ], text=True).strip()


def idle_window(nvml, uuid, seconds=10):
    require_exclusive(uuid)
    start = time.monotonic()
    first = nvml.energy()
    readings = []
    while time.monotonic() - start < seconds:
        require_exclusive(uuid)
        readings.append([time.monotonic() - start, nvml.power()])
        time.sleep(0.25)
    last = nvml.energy()
    duration = time.monotonic() - start
    assert last > first
    return {'energy_start_mj': first, 'energy_end_mj': last, 'wall_s': duration,
            'mean_w': (last - first) / 1000 / duration, 'power_samples': readings}


def active_window(graph, calls_per_graph, nvml, uuid, seconds=10):
    require_exclusive(uuid)
    stop = threading.Event()
    errors = []
    readings = []

    def monitor():
        last_check = 0
        try:
            while not stop.is_set():
                now = time.monotonic()
                if now - last_check >= 1:
                    require_exclusive(uuid)
                    last_check = now
                readings.append([now, nvml.power(), nvml.energy()])
                stop.wait(0.05)
        except Exception as error:
            errors.append(repr(error))

    torch.cuda.synchronize()
    watcher = threading.Thread(target=monitor, daemon=True)
    watcher.start()
    first = nvml.energy()
    start = time.monotonic()
    batches = 0
    try:
        while time.monotonic() - start < seconds:
            graph.replay()
            torch.cuda.synchronize()
            batches += 1
            if errors:
                raise RuntimeError(errors[0])
        torch.cuda.synchronize()
        last = nvml.energy()
        duration = time.monotonic() - start
    finally:
        stop.set()
        watcher.join(timeout=5)
    require_exclusive(uuid)
    assert not errors and batches > 0 and last > first
    joules = (last - first) / 1000
    count = batches * calls_per_graph
    relative_error = None
    if len(readings) > 2:
        integral = sum((right[0] - left[0]) * (left[1] + right[1]) / 2
                       for left, right in zip(readings, readings[1:]))
        covered_s = readings[-1][0] - readings[0][0]
        relative_error = abs(integral / covered_s - joules / duration) / (joules / duration)
        assert relative_error < 0.15, 'Energy counter / power sensor disagreement'
    return {'energy_start_mj': first, 'energy_end_mj': last, 'energy_j': joules,
            'wall_s': duration, 'actual_sdpa_calls': count, 'mean_board_w': joules / duration,
            'gross_uj_per_sdpa': joules / count * 1e6, 'sustained_ms_per_sdpa':
            duration / count * 1000, 'power_counter_relative_disagreement': relative_error,
            'samples': readings, 'telemetry_after': telemetry(uuid)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vector', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    assert baseline['status'] == 'pass_timing_only'
    assert sha(args.vector) == baseline['vector_sha256']
    uuid = baseline['gpu_uuid']
    visible_uuid = subprocess.check_output([
        'nvidia-smi', '-i', os.environ.get('CUDA_VISIBLE_DEVICES', '0'),
        '--query-gpu=uuid', '--format=csv,noheader',
    ], text=True).strip()
    assert visible_uuid == uuid
    require_exclusive(uuid)
    nvml = Nvml(uuid)
    torch.set_grad_enabled(False)
    torch.set_num_threads(4)
    payload = torch.load(args.vector, map_location='cpu', weights_only=True)
    qkv = [payload[name].to('cuda', dtype=torch.float16).contiguous()
           for name in ('q', 'k', 'v')]
    reference = payload['o'].to('cuda').float()
    backend = getattr(SDPBackend, baseline['gpu_backend']['backend'])
    report = {'status': 'running', 'vector_sha256': sha(args.vector),
              'baseline_sha256': sha(args.baseline), 'gpu_uuid': uuid,
              'shape': list(qkv[0].shape), 'dtype': 'FP16', 'backend': backend.name,
              'metadata': payload['metadata'], 'torch': torch.__version__,
              'scope': 'gross NVML board energy of resident repeated full-head SDPA',
              'excluded': 'host/CPU energy, PCIe, QKV/output projections, RoPE, MLP',
              'protocol': '3x10-second sustained windows; 10-second pre/post idle and warm load',
              'sustained_replay_is_not_isolated_call_latency': True}
    with sdpa_kernel(backend):
        answer = functional.scaled_dot_product_attention(*qkv)
        relative = float((answer.float() - reference).norm() /
                         reference.norm().clamp_min(1e-12))
        assert relative <= 0.005
        for _ in range(20):
            answer = functional.scaled_dot_product_attention(*qkv)
        torch.cuda.synchronize()
        graph = torch.cuda.CUDAGraph()
        calls = 32
        outputs = []
        with torch.cuda.graph(graph):
            for _ in range(calls):
                outputs.append(functional.scaled_dot_product_attention(*qkv))
        graph.replay()
        torch.cuda.synchronize()
        report['idle_before'] = idle_window(nvml, uuid)
        start = time.monotonic()
        last_check = start
        while time.monotonic() - start < 10:
            if time.monotonic() - last_check >= 1:
                require_exclusive(uuid)
                last_check = time.monotonic()
            graph.replay()
            torch.cuda.synchronize()
        report['telemetry_before'] = telemetry(uuid)
        report['trials'] = [active_window(graph, calls, nvml, uuid) for _ in range(3)]
        report['idle_after'] = idle_window(nvml, uuid)
    energies = [trial['gross_uj_per_sdpa'] for trial in report['trials']]
    report.update(status='pass_energy_only', median_gross_uj_per_sdpa=statistics.median(energies),
                  minimum_gross_uj_per_sdpa=min(energies),
                  maximum_gross_uj_per_sdpa=max(energies),
                  numerical_equivalence_to_asic_not_qualified=True)
    write_json(args.output, report)
    print('GPU_ENERGY_PASS', report['shape'], report['median_gross_uj_per_sdpa'], flush=True)


if __name__ == '__main__':
    main()
