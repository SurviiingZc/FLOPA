"""Read energy-counter support without creating CUDA contexts or changing settings."""

import ctypes
import json


lib = ctypes.CDLL('libnvidia-ml.so.1')
lib.nvmlInit_v2.restype = ctypes.c_int
lib.nvmlDeviceGetHandleByIndex_v2.argtypes = [ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p)]
lib.nvmlDeviceGetTotalEnergyConsumption.argtypes = [
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulonglong),
]
assert lib.nvmlInit_v2() == 0
for index in (0, 1):
    handle = ctypes.c_void_p()
    assert lib.nvmlDeviceGetHandleByIndex_v2(index, ctypes.byref(handle)) == 0
    energy = ctypes.c_ulonglong()
    code = lib.nvmlDeviceGetTotalEnergyConsumption(handle, ctypes.byref(energy))
    print(json.dumps({'index': index, 'return_code': code, 'total_energy_mj': energy.value}))
assert lib.nvmlShutdown() == 0
