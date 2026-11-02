"""Chunked, integer-exact Torch shadow of the frozen FLOPA arithmetic.

This is a numerical emulator, not an accelerator timing or power model. Q/K/V
must already be INT8 codes. No projection, scale calibration, or dequantization
is hidden inside the attention operation. Both P and alpha use the original
eight-segment PWL exponential; no ideal exponential is used.

QK uses FP32 bmm with TF32 disabled: d <= 128 bounds the absolute integer sum by
2**21, so every product and sum is exactly representable. PV uses FP64 bmm for
at most 32 products of Q1.15 probability and INT8 V, an integer sum below 2**27.
Casting that exact sum to INT64 and wrapping once equals sequential INT32 PE
addition modulo 2**32. Rescaling is performed between KV tiles, as in the RTL.

The default unity_bypass=False reproduces fixed_point_shadow.py. Enabling it is
an explicit alternate recurrence: unchanged row maxima bypass alpha rescaling.
The caller must bind this option to the audited RTL revision, never to quality.
"""

from contextlib import contextmanager
from typing import Optional

import torch


EXP_ENDPOINTS = (32767, 12055, 4435, 1632, 600, 221, 81, 30, 11)
RECIP_SEEDS = (
    32767, 30840, 29127, 27594, 26214, 24966, 23831, 22795,
    21845, 20972, 20165, 19418, 18725, 18079, 17476, 16913,
)


def wrap32(value):
    """INT32 modular arithmetic with an INT64 result tensor."""
    return torch.bitwise_and(value + (1 << 31), 0xFFFFFFFF) - (1 << 31)


def rounded_shift(value, shift):
    """Arithmetic right shift with ties away from zero, for shifts 0..63."""
    shift = torch.as_tensor(shift, dtype=torch.int64, device=value.device)
    mask = torch.bitwise_right_shift(
        torch.full_like(shift, 0x7FFFFFFFFFFFFFFF), 63 - shift
    )
    remainder = torch.bitwise_and(value, mask)
    half = torch.bitwise_left_shift(torch.ones_like(shift), (shift - 1).clamp_min(0))
    increment = (remainder > half) | ((remainder == half) & (value >= 0))
    rounded = torch.bitwise_right_shift(value, shift) + increment.to(torch.int64)
    return torch.where(shift == 0, value, rounded)


def scale_scores(value, register):
    register = torch.as_tensor(register, dtype=torch.int64, device=value.device)
    product = value * torch.bitwise_and(register, 65535)
    shift = torch.bitwise_and(torch.bitwise_right_shift(register, 16), 63)
    truncated = torch.bitwise_right_shift(product, shift)
    base = truncated.clamp(-65536, 65535)
    increment = rounded_shift(product, shift) - truncated
    return (base + increment).clamp(-32768, 32767)


def pwl(value):
    endpoints = torch.tensor(EXP_ENDPOINTS, dtype=torch.int64, device=value.device)
    magnitude = (-value).clamp(0, 2047)
    segment = torch.bitwise_right_shift(magnitude, 8)
    fraction = torch.bitwise_and(magnitude, 255)
    result = endpoints[segment] - torch.bitwise_right_shift(
        (endpoints[segment] - endpoints[segment + 1]) * fraction, 8
    )
    return torch.where(value >= 0, 32767, torch.where(value <= -2048, 0, result))


def reciprocal(value):
    """Original 16-seed reciprocal, including the early exponent shift."""
    seeds = torch.tensor(RECIP_SEEDS, dtype=torch.int64, device=value.device)
    msb = torch.zeros_like(value)
    remaining = value
    for bits in (16, 8, 4, 2, 1):
        shifted = torch.bitwise_right_shift(remaining, bits)
        selected = shifted != 0
        msb = msb + selected.to(torch.int64) * bits
        remaining = torch.where(selected, shifted, remaining)
    normalized = torch.where(
        msb >= 15,
        torch.bitwise_right_shift(value, (msb - 15).clamp_min(0)),
        torch.bitwise_left_shift(value, (15 - msb).clamp_min(0)),
    )
    seed = seeds[torch.bitwise_and(torch.bitwise_right_shift(normalized, 11), 15)]
    answer = torch.where(
        msb > 15,
        torch.bitwise_right_shift(seed, (msb - 15).clamp_min(0)),
        torch.bitwise_left_shift(seed, (15 - msb).clamp_min(0)),
    )
    return torch.where(value == 0, 0, answer)


@contextmanager
def _exact_fp32_matmul():
    previous = torch.backends.cuda.matmul.allow_tf32
    torch.backends.cuda.matmul.allow_tf32 = False
    try:
        yield
    finally:
        torch.backends.cuda.matmul.allow_tf32 = previous


def _as_bhnd(value, name):
    if value.ndim not in (2, 3, 4):
        raise ValueError(f"{name} must use ND, HND, or BHND layout")
    if value.dtype != torch.int8:
        raise TypeError(f"{name} must contain INT8 codes, got {value.dtype}")
    if value.ndim == 2:
        return value[None, None]
    if value.ndim == 3:
        return value[None]
    return value


def _registers(value, batch, heads, device):
    value = torch.as_tensor(value, dtype=torch.int64, device=device)
    try:
        value = torch.broadcast_to(value, (batch, heads))
    except RuntimeError as error:
        raise ValueError("register must broadcast to [batch, heads]") from error
    if bool(((value < 0) | (value > 0xFFFFFFFF)).any().item()):
        raise ValueError("register must be an unsigned 32-bit value")
    return value.reshape(batch * heads)


def _restore_layout(value, original_ndim):
    if original_ndim == 2:
        return value[0, 0]
    if original_ndim == 3:
        return value[0]
    return value


@torch.no_grad()
def quantize_half_away(value, scale, limit=127):
    """Frozen host rule: round halves away from zero, then clip to +/-limit."""
    if limit not in (127, 128):
        raise ValueError("limit must be 127 or 128")
    scale = torch.as_tensor(scale, device=value.device, dtype=torch.float32)
    if bool(((scale <= 0) | ~torch.isfinite(scale)).any().item()):
        raise ValueError("quantization scale must be positive and finite")
    raw = value.to(torch.float32) / scale
    codes = torch.sign(raw) * torch.floor(torch.abs(raw) + 0.5)
    lower = -limit
    upper = 127
    clipped = ((codes < lower) | (codes > upper)).sum().item()
    return codes.clamp(lower, upper).to(torch.int8), int(clipped)


@torch.no_grad()
def shadow_attention(
    q,
    k,
    v,
    score_register,
    out_register,
    *,
    query_chunk_size=1024,
    batch_head_chunk_size=32,
    unity_bypass=False,
    return_state=False,
    track_pe_overflow=False,
):
    """Return (INT8 output, statistics), optionally followed by final (acc, l).

    Register tensors may be scalar or broadcastable to [batch, heads]. KV tiles
    are always visited in original order with size 32. Query/head chunks only
    change independent work partitioning. All valid queries and KV rows are used.
    Optional per-PE overflow tracking allocates [chunk_heads, chunk_q, 32, d]
    INT64 intermediates; decrease chunks when enabling it. Without tracking,
    pv_overflow_events is None rather than an unmeasured zero.
    """
    original_ndim = q.ndim
    q, k, v = (_as_bhnd(value, name) for value, name in ((q, "q"), (k, "k"), (v, "v")))
    batch, heads, nq, dim = q.shape
    if k.shape[:2] != (batch, heads) or v.shape[:2] != (batch, heads):
        raise ValueError("Q/K/V batch and head counts must match")
    if k.shape[2] != v.shape[2] or k.shape[3] != dim or v.shape[3] != dim:
        raise ValueError("Q/K/V must share d, and K/V must share sequence length")
    nkv = k.shape[2]
    if not 1 <= dim <= 128 or min(batch, heads, nq, nkv) < 1:
        raise ValueError("positive dimensions and 1 <= d <= 128 are required")
    if q.device != k.device or q.device != v.device:
        raise ValueError("Q/K/V must be on one device")
    if query_chunk_size < 1 or batch_head_chunk_size < 1:
        raise ValueError("chunk sizes must be positive")
    device = q.device
    score_regs = _registers(score_register, batch, heads, device)
    out_regs = _registers(out_register, batch, heads, device)
    q = q.reshape(batch * heads, nq, dim)
    k = k.reshape(batch * heads, nkv, dim)
    v = v.reshape(batch * heads, nkv, dim)
    output = torch.empty((batch * heads, nq, dim), dtype=torch.int8, device=device)
    final_acc = torch.empty_like(output, dtype=torch.int64) if return_state else None
    final_l = torch.empty((batch * heads, nq), dtype=torch.int64, device=device)
    counters = torch.zeros(5, dtype=torch.int64, device=device)
    maximum_pre_wrap = torch.zeros((), dtype=torch.int64, device=device)

    with _exact_fp32_matmul():
        for head_start in range(0, batch * heads, batch_head_chunk_size):
            head_end = min(head_start + batch_head_chunk_size, batch * heads)
            keys = k[head_start:head_end].to(torch.float32)
            values = v[head_start:head_end].to(torch.float64)
            score_reg = score_regs[head_start:head_end, None]
            out_reg = out_regs[head_start:head_end, None, None]
            for row_start in range(0, nq, query_chunk_size):
                row_end = min(row_start + query_chunk_size, nq)
                queries = q[head_start:head_end, row_start:row_end].to(torch.float32)
                shape = (head_end - head_start, row_end - row_start)
                maximum: Optional[torch.Tensor] = None
                denominator = torch.zeros(shape, dtype=torch.int64, device=device)
                acc = torch.zeros((*shape, dim), dtype=torch.int64, device=device)
                for col_start in range(0, nkv, 32):
                    col_end = min(col_start + 32, nkv)
                    key_tile = keys[:, col_start:col_end]
                    value_tile = values[:, col_start:col_end]
                    scores = torch.bmm(queries, key_tile.transpose(1, 2)).to(torch.int64)
                    tile_maximum = scores.amax(dim=2)
                    if maximum is None:
                        new_maximum = tile_maximum
                        alpha = torch.zeros_like(new_maximum)
                        unchanged = torch.zeros_like(new_maximum, dtype=torch.bool)
                    else:
                        new_maximum = torch.maximum(maximum, tile_maximum)
                        alpha = pwl(scale_scores(maximum - new_maximum, score_reg))
                        unchanged = maximum == new_maximum
                    probability = pwl(scale_scores(
                        scores - new_maximum[:, :, None], score_reg[:, :, None]
                    ))
                    scaled_l = torch.bitwise_right_shift(denominator * alpha, 15)
                    seed = torch.bitwise_right_shift(acc * alpha[:, :, None], 15)
                    if unity_bypass:
                        scaled_l = torch.where(unchanged, denominator, scaled_l)
                        seed = torch.where(unchanged[:, :, None], acc, seed)
                    raw_l = scaled_l + probability.sum(dim=2)
                    counters[0] += (raw_l > 0xFFFFFFFF).sum()
                    denominator = raw_l.clamp_max(0xFFFFFFFF)
                    counters[1] += (probability == 0).sum()
                    counters[2] += probability.numel()
                    tile_products = torch.bmm(probability.to(torch.float64), value_tile)
                    acc = wrap32(seed + tile_products.to(torch.int64))
                    if track_pe_overflow:
                        products = probability[:, :, :, None] * value_tile.to(torch.int64)[:, None]
                        prefixes = products.cumsum(dim=2)
                        previous = torch.cat((
                            seed[:, :, None],
                            wrap32(seed[:, :, None] + prefixes[:, :, :-1]),
                        ), dim=2)
                        raw = previous + products
                        counters[4] += ((raw < -(1 << 31)) | (raw >= (1 << 31))).sum()
                        maximum_pre_wrap = torch.maximum(maximum_pre_wrap, raw.abs().amax())
                    maximum = new_maximum
                normalized = torch.bitwise_right_shift(
                    acc * reciprocal(denominator)[:, :, None], 15
                )
                result = rounded_shift(
                    normalized * torch.bitwise_and(out_reg, 65535),
                    torch.bitwise_and(torch.bitwise_right_shift(out_reg, 16), 63),
                )
                counters[3] += ((result < -128) | (result > 127)).sum()
                output[head_start:head_end, row_start:row_end] = result.clamp(-128, 127)
                final_l[head_start:head_end, row_start:row_end] = denominator
                if return_state:
                    final_acc[head_start:head_end, row_start:row_end] = acc

    counts = counters.cpu().tolist()
    stats = {
        "query_rows": nq,
        "kv_rows": nkv,
        "batch": batch,
        "heads": heads,
        "full_query_coverage": True,
        "all_kv_rows_checked": True,
        "row_sum_saturations": counts[0],
        "p_zero": counts[1],
        "p_total": counts[2],
        "output_saturations": counts[3],
        "pv_overflow_events": counts[4] if track_pe_overflow else None,
        "max_absolute_pre_wrap": int(maximum_pre_wrap.item()) if track_pe_overflow else None,
        "unity_bypass": bool(unity_bypass),
        "arithmetic": "eight-segment PWL; 16-seed early-shift reciprocal; INT32 wrap",
        "pv_reduction": "exact integer sum via FP64 bmm then INT32 modular addition",
    }
    output = _restore_layout(output.reshape(batch, heads, nq, dim), original_ndim)
    if return_state:
        final_acc = _restore_layout(final_acc.reshape(batch, heads, nq, dim), original_ndim)
        final_l = _restore_layout(final_l.reshape(batch, heads, nq), original_ndim)
        return output, stats, final_acc, final_l
    return output, stats


shadow = shadow_attention
