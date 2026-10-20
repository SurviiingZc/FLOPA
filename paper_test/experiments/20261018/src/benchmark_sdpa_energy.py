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


ALLOW_SHARED = False


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


def observe_background(uuid):
    raw = subprocess.check_output([
        'nvidia-smi', '--query-compute-apps=gpu_uuid,pid,used_memory',
        '--format=csv,noheader,nounits',
    ], text=True)
    foreign = []
    for line in raw.splitlines():
        device, pid, memory = [field.strip() for field in line.split(',')]
        if device == uuid and int(pid) != os.getpid():
            foreign.append({'pid': int(pid), 'memory_mib': int(memory), 'uuid': device})
    if foreign and not ALLOW_SHARED:
        raise RuntimeError('Energy window has another compute process: ' + str(foreign))
    return foreign


def telemetry(uuid):
    fields = 'uuid,power.draw,clocks.sm,clocks.mem,temperature.gpu,pstate,power.limit'
    return subprocess.check_output([
        'nvidia-smi', '-i', uuid, '--query-gpu=' + fields, '--format=csv,noheader',
    ], text=True).strip()


def idle_window(nvml, uuid, seconds=10):
    background = [[time.monotonic(), observe_background(uuid)]]
    start = time.monotonic()
    first = nvml.energy()
    readings = []
    while time.monotonic() - start < seconds:
        background.append([time.monotonic(), observe_background(uuid)])
        readings.append([time.monotonic() - start, nvml.power()])
        time.sleep(0.25)
    last = nvml.energy()
    duration = time.monotonic() - start
    assert last > first
    return {'energy_start_mj': first, 'energy_end_mj': last, 'wall_s': duration,
            'mean_w': (last - first) / 1000 / duration, 'power_samples': readings,
            'background_process_samples': background}


def active_window(graph, calls_per_graph, nvml, uuid, seconds=10):
    background = [[time.monotonic(), observe_background(uuid)]]
    stop = threading.Event()
    errors = []
    readings = []

    def monitor():
        last_check = 0
        try:
            while not stop.is_set():
                now = time.monotonic()
                if now - last_check >= 1:
                    background.append([now, observe_background(uuid)])
                    last_check = now
                readings.append([time.monotonic(), nvml.power(), nvml.energy()])
                stop.wait(0.05)
        except Exception as error:
            errors.append(repr(error))

    torch.cuda.synchronize()
    watcher = threading.Thread(target=monitor, daemon=True)
    watcher.start()
    first = nvml.energy()
    first_power = nvml.power()
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
        last_power = nvml.power()
    finally:
        stop.set()
        watcher.join(timeout=5)
    background.append([time.monotonic(), observe_background(uuid)])
    assert not errors and batches > 0 and last > first
    counter_joules = (last - first) / 1000
    count = batches * calls_per_graph
    assert len(readings) > 20
    points = [[start, first_power]] + [item[:2] for item in readings
                                     if start < item[0] < start + duration]
    points.append([start + duration, last_power])
    joules = sum((right[0] - left[0]) * (left[1] + right[1]) / 2
                 for left, right in zip(points, points[1:]))
    assert joules > 0 and all(item[1] > 0 for item in points)
    relative_error = abs(joules - counter_joules) / counter_joules
    return {'energy_start_mj': first, 'energy_end_mj': last, 'energy_j': joules,
            'window_start_monotonic_s': start, 'window_end_monotonic_s': start + duration,
            'endpoint_board_power_w': [first_power, last_power],
            'energy_method': 'NVML board-power trapezoidal integration over actual window',
            'counter_energy_j': counter_joules,
            'counter_consistency_pass': relative_error < 0.15,
            'wall_s': duration, 'actual_sdpa_calls': count, 'mean_board_w': joules / duration,
            'gross_uj_per_sdpa': joules / count * 1e6, 'sustained_ms_per_sdpa':
            duration / count * 1000, 'power_counter_relative_disagreement': relative_error,
            'samples': readings, 'telemetry_after': telemetry(uuid),
            'background_process_samples': background}


def main():
    global ALLOW_SHARED
    parser = argparse.ArgumentParser()
    parser.add_argument('--vector', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--allow-shared', action='store_true')
    args = parser.parse_args()
    ALLOW_SHARED = args.allow_shared
    baseline = json.loads(args.baseline.read_text())
    assert baseline['status'] == 'pass_timing_only'
    assert sha(args.vector) == baseline['vector_sha256']
    uuid = baseline['gpu_uuid']
    visible_uuid = subprocess.check_output([
        'nvidia-smi', '-i', os.environ.get('CUDA_VISIBLE_DEVICES', '0'),
        '--query-gpu=uuid', '--format=csv,noheader',
    ], text=True).strip()
    assert visible_uuid == uuid
    initial_background = observe_background(uuid)
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
              'scope': 'gross NVML board-power integral for repeated full-head SDPA',
              'excluded': 'host/CPU energy, PCIe, QKV/output projections, RoPE, MLP',
              'protocol': '3x10-second sustained windows; 10-second pre/post idle and warm load',
              'sustained_replay_is_not_isolated_call_latency': True}
    report.update(shared_environment_authorized=ALLOW_SHARED,
                  foreign_processes_at_start=initial_background,
                  measurement_condition=('shared-board gross energy; background included'
                                         if ALLOW_SHARED else 'exclusive compute admission'))
    report['energy_method'] = 'NVML board-power trapezoidal integration'
    report['counter_used_as_diagnostic_only'] = True
    report['measurement_script_sha256'] = sha(Path(__file__))
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
                observe_background(uuid)
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
