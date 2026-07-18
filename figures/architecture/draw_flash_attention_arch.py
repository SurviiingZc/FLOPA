#!/usr/bin/env python3
"""Render the fused FlashAttention accelerator architecture at IEEE two-column width."""

from pathlib import Path
import xml.etree.ElementTree as ET

import matplotlib as mpl
from PIL import Image

mpl.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Rectangle


FIG_WIDTH_MM = 183.0
FIG_HEIGHT_MM = 116.0
FIG_W = FIG_WIDTH_MM / 25.4
FIG_H = FIG_HEIGHT_MM / 25.4

INK = "#202124"
MID = "#5F6368"
GRID = "#A8ADB3"
PALE = "#F7F8FA"
WHITE = "#FFFFFF"
CONTROL = "#D62828"
CONTROL_FILL = "#FCE8E6"
COMPUTE = "#2455D6"
COMPUTE_FILL = "#E8EEFF"
EXP = "#15803D"
EXP_FILL = "#E7F5EA"
STATE = "#7B3FB3"
STATE_FILL = "#F1E8F8"
MEMORY = "#4F6367"
MEMORY_FILL = "#EEF1F2"


def box(ax, x, y, w, h, title="", subtitle="", fill=WHITE, edge=INK,
        lw=0.85, title_color=INK, title_size=6.2, subtitle_size=5.3,
        radius=0.004, zorder=4):
    patch = FancyBboxPatch(
        (x, y), w, h,
        boxstyle=f"round,pad=0.003,rounding_size={radius}",
        facecolor=fill, edgecolor=edge, linewidth=lw, zorder=zorder,
    )
    ax.add_patch(patch)
    if title:
        ax.text(x + w / 2, y + h - 0.018, title, ha="center", va="top",
                fontsize=title_size, fontweight="bold", color=title_color,
                zorder=zorder + 1)
    if subtitle:
        ax.text(x + w / 2, y + 0.018, subtitle, ha="center", va="bottom",
                fontsize=subtitle_size, color=MID, linespacing=1.12,
                zorder=zorder + 1)
    return patch


def arrow(ax, x0, y0, x1, y1, color=INK, lw=1.05, mutation=7,
          linestyle="-", zorder=8, connection="arc3,rad=0"):
    patch = FancyArrowPatch(
        (x0, y0), (x1, y1), arrowstyle="-|>", mutation_scale=mutation,
        linewidth=lw, color=color, linestyle=linestyle,
        connectionstyle=connection, shrinkA=0, shrinkB=0, zorder=zorder,
    )
    ax.add_patch(patch)
    return patch


def line_arrow(ax, points, color=INK, lw=1.05, mutation=7,
               linestyle="-", zorder=8):
    for p0, p1 in zip(points[:-2], points[1:-1]):
        ax.plot([p0[0], p1[0]], [p0[1], p1[1]], color=color,
                linewidth=lw, linestyle=linestyle, zorder=zorder)
    return arrow(ax, *points[-2], *points[-1], color=color, lw=lw,
                 mutation=mutation, linestyle=linestyle, zorder=zorder)


def tag(ax, x, y, text, color=INK, size=5.3, weight="normal",
        ha="center", va="center", rotation=0, zorder=12):
    ax.text(x, y, text, ha=ha, va=va, rotation=rotation, fontsize=size,
            fontweight=weight, color=color,
            bbox=dict(facecolor=WHITE, edgecolor="none", pad=0.7, alpha=0.94),
            zorder=zorder)


def phase_badge(ax, x, y, number, text, color):
    ax.text(x, y, number, ha="center", va="center", fontsize=5.4,
            fontweight="bold", color=WHITE,
            bbox=dict(boxstyle="circle,pad=0.20", facecolor=color,
                      edgecolor=color, linewidth=0.5), zorder=14)
    ax.text(x + 0.014, y, text, ha="left", va="center", fontsize=5.3,
            fontweight="bold", color=color, zorder=14)


def draw_top_band(ax):
    # ISSCC-like global blocks.
    box(ax, 0.018, 0.805, 0.148, 0.166, "Host / PS", "AXI4-Lite control\n128-bit AXI data",
        fill=CONTROL_FILL, edge=CONTROL, title_color=CONTROL, title_size=6.8)
    box(ax, 0.181, 0.805, 0.263, 0.166, "Q/K/V Ping-Pong Cache", "",
        fill=MEMORY_FILL, edge=MEMORY, title_color=MEMORY, title_size=6.8)
    # Draw six visible banks inside the cache.
    for group, label_text in enumerate(("Q", "K", "V")):
        gx = 0.194 + group * 0.080
        ax.text(gx + 0.031, 0.893, label_text, ha="center", va="center",
                fontsize=5.8, fontweight="bold", color=INK, zorder=8)
        for bank_idx in range(2):
            bx = gx + bank_idx * 0.033
            ax.add_patch(Rectangle((bx, 0.834), 0.028, 0.043,
                                   facecolor=WHITE, edgecolor=MEMORY,
                                   linewidth=0.55, zorder=7))
            ax.text(bx + 0.014, 0.855, f"P{bank_idx}", ha="center", va="center",
                    fontsize=5.0, color=MID, zorder=8)
    ax.text(0.3125, 0.915, "3 x dual-bank local SRAM | 256-bit word = 32 x INT8",
            ha="center", va="center", fontsize=5.0, color=MID, zorder=8)

    box(ax, 0.459, 0.805, 0.257, 0.166, "Top Controller", "Register file | tile scheduler | counters",
        fill=CONTROL_FILL, edge=CONTROL, title_color=CONTROL, title_size=6.8)
    # Compact state strip.
    states = ["LOAD", "QK", "FSA", "PV", "WB"]
    for idx, state in enumerate(states):
        sx = 0.474 + idx * 0.045
        ax.add_patch(Rectangle((sx, 0.842), 0.039, 0.038,
                               facecolor=WHITE, edgecolor=CONTROL,
                               linewidth=0.55, zorder=7))
        ax.text(sx + 0.0195, 0.861, state, ha="center", va="center",
                fontsize=5.0, color=INK, zorder=8)
        if idx < len(states) - 1:
            arrow(ax, sx + 0.039, 0.861, sx + 0.045, 0.861,
                  color=CONTROL, lw=0.65, mutation=4.5, zorder=9)

    box(ax, 0.731, 0.805, 0.251, 0.166, "Output Path", "INT32 row buffer | final normalize\n128-bit AXI4 writeback",
        fill=STATE_FILL, edge=STATE, title_color=STATE, title_size=6.8)
    # Data and control connections.
    arrow(ax, 0.166, 0.887, 0.181, 0.887, color=MEMORY, lw=1.1)
    tag(ax, 0.174, 0.905, "128b", color=MEMORY, size=5.0)
    arrow(ax, 0.092, 0.805, 0.092, 0.790, color=CONTROL, lw=0.85,
          linestyle="--", mutation=6)

    # Physical local interconnect band.
    ax.add_patch(Rectangle((0.018, 0.762), 0.964, 0.028,
                           facecolor=WHITE, edgecolor=INK,
                           linewidth=0.75, zorder=5))
    ax.text(0.500, 0.776, "REGISTERED LOCAL INTERCONNECT / PHASE CONTROL",
            ha="center", va="center", fontsize=5.6, fontweight="bold",
            color=INK, zorder=7)
    arrow(ax, 0.311, 0.805, 0.311, 0.790, color=MEMORY, lw=1.1, mutation=6)
    arrow(ax, 0.587, 0.805, 0.587, 0.790, color=CONTROL, lw=0.9,
          linestyle="--", mutation=6)
    arrow(ax, 0.856, 0.790, 0.856, 0.805, color=STATE, lw=1.1, mutation=6)


def draw_array(ax):
    x, y, w, h = 0.252, 0.346, 0.425, 0.381
    box(ax, x, y, w, h, "Fused OS-FSA Core (32 x 32 PEs)", "4 physical stripes x 8 rows",
        fill=COMPUTE_FILL, edge=COMPUTE, title_color=COMPUTE,
        title_size=7.2, subtitle_size=5.3, lw=1.15)

    gx, gy = x + 0.055, y + 0.068
    gw, gh = w - 0.095, h - 0.131
    rows, cols = 8, 8
    cw, ch = gw / cols, gh / rows
    for rr in range(rows):
        stripe = (rr // 2) % 2
        fill = "#DCE6FF" if stripe == 0 else "#EEF2FF"
        for cc in range(cols):
            ax.add_patch(Rectangle((gx + cc * cw, gy + rr * ch), cw, ch,
                                   facecolor=fill, edgecolor="#7892D8",
                                   linewidth=0.42, zorder=6))
    # Highlight the representative PE expanded below.
    hi_r, hi_c = 5, 5
    ax.add_patch(Rectangle((gx + hi_c * cw, gy + hi_r * ch), cw, ch,
                           facecolor="#CBD6FF", edgecolor=COMPUTE,
                           linewidth=1.1, zorder=7))
    ax.text(gx + (hi_c + 0.5) * cw, gy + (hi_r + 0.5) * ch, "PE",
            ha="center", va="center", fontsize=5.0, fontweight="bold",
            color=COMPUTE, zorder=8)

    # Q and K/V systolic streams.
    arrow(ax, x + 0.010, gy + gh * 0.62, gx - 0.006, gy + gh * 0.62,
          color=COMPUTE, lw=1.35, mutation=7)
    arrow(ax, x + 0.010, gy + gh * 0.38, gx - 0.006, gy + gh * 0.38,
          color=STATE, lw=1.35, mutation=7)
    arrow(ax, gx + gw * 0.30, y + h - 0.057, gx + gw * 0.30, gy + gh + 0.004,
          color=COMPUTE, lw=1.35, mutation=7)
    arrow(ax, gx + gw * 0.70, y + h - 0.057, gx + gw * 0.70, gy + gh + 0.004,
          color=STATE, lw=1.35, mutation=7)
    tag(ax, x + 0.028, gy + gh * 0.62 + 0.020, "Q rows", color=COMPUTE,
        size=5.1, ha="left")
    tag(ax, x + 0.027, gy + gh * 0.38 - 0.020, "P rows", color=STATE,
        size=5.1, ha="left")
    tag(ax, gx + gw * 0.30, gy + gh + 0.012, "K cols", color=COMPUTE, size=5.1)
    tag(ax, gx + gw * 0.70, gy + gh + 0.012, "V cols", color=STATE, size=5.1)

    # In-row nearest-neighbor flows; arrows sit inside the PE fabric.
    yy_max = gy + gh * 0.79
    yy_m = gy + gh * 0.59
    yy_sum = gy + gh * 0.20
    arrow(ax, gx + 0.012, yy_max, gx + gw - 0.010, yy_max,
          color=CONTROL, lw=1.15, mutation=7)
    arrow(ax, gx + gw - 0.010, yy_m, gx + 0.012, yy_m,
          color=STATE, lw=1.15, mutation=7)
    arrow(ax, gx + 0.012, yy_sum, gx + gw - 0.010, yy_sum,
          color=EXP, lw=1.15, mutation=7)
    tag(ax, gx + gw * 0.52, yy_max + 0.017, "staggered rowmax  ->",
        color=CONTROL, size=5.0)
    tag(ax, gx + gw * 0.50, yy_m - 0.017, "<-  m_new + local SUB",
        color=STATE, size=5.0)
    tag(ax, gx + gw * 0.50, yy_sum + 0.017, "prob rowsum  ->",
        color=EXP, size=5.0)

    # Connector from highlighted PE to inset.
    hx = gx + (hi_c + 0.5) * cw
    hy = gy + (hi_r + 0.5) * ch
    line_arrow(ax, [(hx, hy - ch / 2), (hx, y - 0.012), (0.650, y - 0.012),
                    (0.650, 0.286)], color=COMPUTE, lw=0.75,
               linestyle="--", mutation=5, zorder=5)


def draw_side_units(ax):
    # Input skew / wrappers.
    box(ax, 0.018, 0.346, 0.205, 0.381, "Stream Front End", "No matrix-wide output ports",
        fill=MEMORY_FILL, edge=MEMORY, title_color=MEMORY, title_size=6.7)
    box(ax, 0.039, 0.618, 0.163, 0.072, "FSA QK Engine", "Q/K read + valid/last",
        fill=WHITE, edge=COMPUTE, title_color=COMPUTE, title_size=5.9, subtitle_size=5.0)
    box(ax, 0.039, 0.515, 0.163, 0.072, "Registered Skew", "row/column delay lines",
        fill=WHITE, edge=MEMORY, title_color=MEMORY, title_size=5.9, subtitle_size=5.0)
    box(ax, 0.039, 0.412, 0.163, 0.072, "FSA PV Engine", "restore O row + V stream",
        fill=WHITE, edge=STATE, title_color=STATE, title_size=5.9, subtitle_size=5.0)
    arrow(ax, 0.202, 0.654, 0.252, 0.654, color=COMPUTE, lw=1.25)
    arrow(ax, 0.202, 0.448, 0.252, 0.448, color=STATE, lw=1.25)
    line_arrow(ax, [(0.311, 0.762), (0.311, 0.742), (0.120, 0.742),
                    (0.120, 0.690)], color=MEMORY, lw=1.0, mutation=6)

    # Only exp is a shared score/probability arithmetic unit outside PEs.
    box(ax, 0.705, 0.346, 0.277, 0.381, "Array-Side Units", "No score/probability tile buffer",
        fill=PALE, edge=INK, title_size=6.7)
    box(ax, 0.728, 0.615, 0.231, 0.075, "32-Lane Scale + PWL Exp", "shared pipelined nonlinear unit",
        fill=EXP_FILL, edge=EXP, title_color=EXP, title_size=6.1, subtitle_size=5.0)
    box(ax, 0.728, 0.509, 0.231, 0.075, "Row State (m, l, alpha)", "32 rows | local update registers",
        fill=STATE_FILL, edge=STATE, title_color=STATE, title_size=6.1, subtitle_size=5.0)
    box(ax, 0.728, 0.403, 0.231, 0.075, "Final Normalizer", "reciprocal LUT | requantize",
        fill=STATE_FILL, edge=STATE, title_color=STATE, title_size=6.1, subtitle_size=5.0)

    # Narrow, registered array-side interfaces.
    arrow(ax, 0.677, 0.647, 0.728, 0.647, color=EXP, lw=1.2)
    arrow(ax, 0.728, 0.629, 0.677, 0.629, color=EXP, lw=1.2)
    tag(ax, 0.702, 0.669, "32 lanes", color=EXP, size=5.0)
    line_arrow(ax, [(0.677, 0.548), (0.703, 0.548), (0.703, 0.546),
                    (0.728, 0.546)], color=STATE, lw=1.1, mutation=6)
    line_arrow(ax, [(0.959, 0.440), (0.971, 0.440), (0.971, 0.776),
                    (0.856, 0.776)], color=STATE, lw=1.1, mutation=6)
    # Phase badges occupy the narrow strip below the local interconnect.
    phase_badge(ax, 0.267, 0.744, "1", "QK + MAX", COMPUTE)
    phase_badge(ax, 0.466, 0.744, "2", "reverse m / SUB", STATE)
    phase_badge(ax, 0.682, 0.744, "3", "EXP WB + SUM", EXP)
    phase_badge(ax, 0.855, 0.744, "4", "P x V MAC", STATE)


def draw_pe_inset(ax):
    x, y, w, h = 0.018, 0.028, 0.964, 0.271
    box(ax, x, y, w, h, "Representative Fused PE", "registered nearest-neighbor links; no global row MUX",
        fill=WHITE, edge=INK, title_size=6.8, subtitle_size=5.1, lw=0.9)

    # I/O register group.
    box(ax, 0.040, 0.093, 0.120, 0.132, "Systolic I/O", "Q -> | K/V down\nvalid + last",
        fill=MEMORY_FILL, edge=MEMORY, title_color=MEMORY, title_size=5.9, subtitle_size=5.0)

    # Arithmetic core with explicit functions beyond MAC.
    box(ax, 0.194, 0.076, 0.263, 0.166, "Mode-Selected Arithmetic", "",
        fill=COMPUTE_FILL, edge=COMPUTE, title_color=COMPUTE, title_size=6.2, subtitle_size=5.0)
    ops = [
        ("MAC", "acc += x*y", COMPUTE, "#F6F8FF"),
        ("MAX", "max(x, pass)", CONTROL, "#FFF5F4"),
        ("SUB", "score - m", STATE, "#FAF5FE"),
        ("ADD", "sum + prob", EXP, "#F3FBF5"),
    ]
    for idx, (name, desc, color, fill) in enumerate(ops):
        ox = 0.208 + (idx % 2) * 0.119
        oy = 0.153 - (idx // 2) * 0.058
        ax.add_patch(Rectangle((ox, oy), 0.108, 0.044,
                               facecolor=fill, edgecolor=color,
                               linewidth=0.65, zorder=7))
        ax.text(ox + 0.022, oy + 0.022, name, ha="center", va="center",
                fontsize=5.2, fontweight="bold", color=color, zorder=8)
        ax.text(ox + 0.074, oy + 0.022, desc, ha="center", va="center",
                fontsize=5.0, color=INK, zorder=8)

    # PE-local state bank.
    box(ax, 0.492, 0.076, 0.222, 0.166, "PE-Local State", "stationary across each tile",
        fill=STATE_FILL, edge=STATE, title_color=STATE, title_size=6.2, subtitle_size=5.0)
    state_regs = [("score_reg", "INT32"), ("prob_reg", "INT16"), ("O_acc", "INT32")]
    for idx, (name, width) in enumerate(state_regs):
        sy = 0.172 - idx * 0.047
        ax.add_patch(Rectangle((0.510, sy), 0.184, 0.035,
                               facecolor=WHITE, edgecolor=STATE,
                               linewidth=0.55, zorder=7))
        ax.text(0.525, sy + 0.0175, name, ha="left", va="center",
                fontsize=5.1, fontweight="bold", color=STATE, zorder=8)
        ax.text(0.680, sy + 0.0175, width, ha="right", va="center",
                fontsize=5.0, color=MID, zorder=8)

    # Nearest-neighbor links.
    box(ax, 0.749, 0.076, 0.211, 0.166, "Row Restream Links", "fixed-width, one-hop registers",
        fill=EXP_FILL, edge=EXP, title_color=EXP, title_size=6.2, subtitle_size=5.0)
    paths = [
        (0.187, "max pass", CONTROL, "->"),
        (0.151, "m_new / SUB", STATE, "<-"),
        (0.115, "rowsum pass", EXP, "->"),
    ]
    for yy, name, color, direction in paths:
        ax.text(0.772, yy, direction, ha="left", va="center", fontsize=7.0,
                fontweight="bold", color=color, zorder=8)
        ax.text(0.805, yy, name, ha="left", va="center", fontsize=5.2,
                fontweight="bold", color=color, zorder=8)
    arrow(ax, 0.160, 0.158, 0.194, 0.158, color=COMPUTE, lw=1.0, mutation=6)
    arrow(ax, 0.457, 0.158, 0.492, 0.158, color=COMPUTE, lw=1.0, mutation=6)
    arrow(ax, 0.714, 0.158, 0.749, 0.158, color=STATE, lw=1.0, mutation=6)


def validate_outputs(output_dir):
    png_path = output_dir / "flash_attention_accelerator_architecture.png"
    tiff_path = output_dir / "flash_attention_accelerator_architecture.tiff"
    svg_path = output_dir / "flash_attention_accelerator_architecture.svg"
    svg_text = svg_path.read_text(encoding="utf-8")
    svg_path.write_text("\n".join(line.rstrip() for line in svg_text.splitlines()) + "\n",
                        encoding="utf-8")
    # Matplotlib/Pillow use truncation for the raster canvas dimensions.
    expected_px = (int(FIG_W * 600), int(FIG_H * 600))
    with Image.open(png_path) as image:
        if image.size != expected_px:
            raise RuntimeError(f"PNG size {image.size} != expected {expected_px}")
        if image.getbbox() is None:
            raise RuntimeError("PNG render is blank")
    with Image.open(tiff_path) as image:
        if image.size != expected_px:
            raise RuntimeError(f"TIFF size {image.size} != expected {expected_px}")
    root = ET.parse(svg_path).getroot()
    if not any(element.tag.endswith("text") for element in root.iter()):
        raise RuntimeError("SVG text is not editable")


def render(output_dir):
    mpl.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["Arial", "Helvetica", "Liberation Sans", "DejaVu Sans"],
        "font.size": 6.3,
        "axes.linewidth": 0.8,
        "svg.fonttype": "none",
        "pdf.fonttype": 42,
        "pdf.use14corefonts": False,
        "savefig.facecolor": WHITE,
    })

    fig = plt.figure(figsize=(FIG_W, FIG_H), facecolor=WHITE)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    draw_top_band(ax)
    draw_side_units(ax)
    draw_array(ax)
    draw_pe_inset(ax)

    output_dir.mkdir(parents=True, exist_ok=True)
    stem = output_dir / "flash_attention_accelerator_architecture"
    fig.savefig(stem.with_suffix(".svg"))
    fig.savefig(stem.with_suffix(".pdf"))
    fig.savefig(stem.with_suffix(".png"), dpi=600)
    fig.savefig(stem.with_suffix(".tiff"), dpi=600,
                pil_kwargs={"compression": "tiff_lzw"})
    plt.close(fig)
    validate_outputs(output_dir)


if __name__ == "__main__":
    render(Path(__file__).resolve().parent)
