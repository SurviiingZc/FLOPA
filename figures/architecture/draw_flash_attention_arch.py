#!/usr/bin/env python3
"""Render the FlashAttention accelerator architecture at IEEE two-column width."""

from pathlib import Path
import xml.etree.ElementTree as ET

import matplotlib as mpl
from PIL import Image

mpl.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Rectangle


FIG_WIDTH_MM = 181.864
FIG_W = FIG_WIDTH_MM / 25.4
FIG_H = 4.15

NAVY = "#17324D"
INK = "#243746"
MUTED = "#5E6B75"
GRID = "#9BAAB5"
DATA = "#136F73"
STATE = "#B23A6F"
CONTROL = "#B87918"
MEM_FILL = "#DDEFE9"
COMPUTE_FILL = "#DCE9F5"
SOFTMAX_FILL = "#F4E2E6"
OUTPUT_FILL = "#F4EBCF"
CONTROL_FILL = "#F2F0EA"
PAPER = "#FFFFFF"
CHIP_FILL = "#FAFBFC"


def rounded_box(ax, x, y, w, h, title, lines=(), fill=PAPER, edge=NAVY,
                title_size=7.2, body_size=5.8, lw=1.0, radius=0.012,
                title_color=NAVY, zorder=5):
    patch = FancyBboxPatch(
        (x, y), w, h,
        boxstyle="round,pad=0.004,rounding_size={}".format(radius),
        linewidth=lw, edgecolor=edge, facecolor=fill, zorder=zorder,
    )
    ax.add_patch(patch)
    ax.text(x + w / 2, y + h - 0.024, title, ha="center", va="top",
            fontsize=title_size, fontweight="bold", color=title_color,
            zorder=zorder + 1)
    if lines:
        line_h = 0.038
        start_y = y + h - 0.061
        for idx, line in enumerate(lines):
            ax.text(x + w / 2, start_y - idx * line_h, line,
                    ha="center", va="top", fontsize=body_size, color=INK,
                    zorder=zorder + 1)
    return patch


def arrow(ax, start, end, color=DATA, lw=1.25, style="-", rad=0.0,
          mutation=8, zorder=4):
    patch = FancyArrowPatch(
        start, end, arrowstyle="-|>", mutation_scale=mutation,
        linewidth=lw, linestyle=style, color=color,
        connectionstyle="arc3,rad={}".format(rad),
        shrinkA=0, shrinkB=0, zorder=zorder,
    )
    ax.add_patch(patch)
    return patch


def poly_arrow(ax, points, color=DATA, lw=1.25, style="-", mutation=8,
               zorder=4):
    for start, end in zip(points[:-2], points[1:-1]):
        ax.plot([start[0], end[0]], [start[1], end[1]], color=color,
                linewidth=lw, linestyle=style, solid_capstyle="round",
                zorder=zorder)
    return arrow(ax, points[-2], points[-1], color=color, lw=lw,
                 style=style, mutation=mutation, zorder=zorder)


def label(ax, x, y, text, color=MUTED, size=5.4, ha="center", va="center",
          weight="normal", zorder=8, background=True):
    bbox = None
    if background:
        bbox = dict(boxstyle="round,pad=0.12", facecolor=PAPER,
                    edgecolor="none", alpha=0.94)
    ax.text(x, y, text, ha=ha, va=va, fontsize=size, color=color,
            fontweight=weight, bbox=bbox, zorder=zorder)


def draw_cache(ax):
    x, y, w, h = 0.177, 0.245, 0.155, 0.515
    rounded_box(ax, x, y, w, h, "Q/K/V tile cache", (), MEM_FILL)
    ax.text(x + w / 2, y + h - 0.052, "ping-pong banks", ha="center",
            va="top", fontsize=5.7, color=MUTED, zorder=7)
    names = ["Q", "K", "V"]
    base_y = y + h - 0.118
    cell_h = 0.096
    for idx, name in enumerate(names):
        cy = base_y - idx * 0.122
        ax.add_patch(FancyBboxPatch(
            (x + 0.017, cy - cell_h), w - 0.034, cell_h,
            boxstyle="round,pad=0.003,rounding_size=0.008",
            linewidth=0.7, edgecolor=DATA, facecolor=PAPER, zorder=6,
        ))
        ax.text(x + 0.032, cy - cell_h / 2, name, ha="center", va="center",
                fontsize=7.1, fontweight="bold", color=NAVY, zorder=7)
        for bank in range(2):
            bx = x + 0.050 + bank * 0.042
            ax.add_patch(Rectangle(
                (bx, cy - 0.071), 0.033, 0.050,
                linewidth=0.55, edgecolor=GRID,
                facecolor="#F7FCFA", zorder=7,
            ))
            ax.text(bx + 0.0165, cy - 0.046, "P{}".format(bank),
                    ha="center", va="center", fontsize=5.0, color=MUTED,
                    zorder=8)
    ax.text(x + w / 2, y + 0.039, "256-bit word = 32 x INT8",
            ha="center", va="center", fontsize=5.6, color=INK, zorder=7)


def draw_array(ax):
    x, y, w, h = 0.465, 0.285, 0.176, 0.445
    rounded_box(ax, x, y, w, h, "Shared OS-FSA", (), COMPUTE_FILL,
                title_size=7.6, lw=1.2)
    ax.text(x + w / 2, y + h - 0.056, "32 x 32 PE array",
            ha="center", va="top", fontsize=6.2, color=INK,
            fontweight="bold", zorder=7)
    gx = x + 0.026
    gy = y + 0.105
    gw = w - 0.052
    gh = h - 0.198
    cols = 8
    rows = 8
    cw = gw / cols
    ch = gh / rows
    stripe_colors = ["#C6DDF0", "#D7E7F4", "#C6DDF0", "#D7E7F4"]
    for stripe in range(4):
        sy = gy + stripe * gh / 4
        ax.add_patch(Rectangle(
            (gx, sy), gw, gh / 4, linewidth=0,
            facecolor=stripe_colors[stripe], zorder=6,
        ))
    for row in range(rows + 1):
        yy = gy + row * ch
        ax.plot([gx, gx + gw], [yy, yy], color=GRID, linewidth=0.38,
                zorder=7)
    for col in range(cols + 1):
        xx = gx + col * cw
        ax.plot([xx, xx], [gy, gy + gh], color=GRID, linewidth=0.38,
                zorder=7)
    ax.add_patch(Rectangle((gx, gy), gw, gh, linewidth=0.8,
                           edgecolor=NAVY, facecolor="none", zorder=8))
    # Highlight one representative PE; the full PE datapath is expanded below.
    pe_col, pe_row = 6, 5
    ax.add_patch(Rectangle(
        (gx + pe_col * cw, gy + pe_row * ch), cw, ch,
        linewidth=0.9, edgecolor=STATE, facecolor="#A9D1DE", zorder=9,
    ))
    ax.text(gx + (pe_col + 0.5) * cw, gy + (pe_row + 0.5) * ch,
            "PE", ha="center", va="center", fontsize=5.0,
            fontweight="bold", color=NAVY, zorder=10)
    ax.text(x + w / 2, y + 0.073, "4 x 8-row physical stripes",
            ha="center", va="center", fontsize=5.4, color=MUTED, zorder=8)
    ax.text(x + w / 2, y + 0.039, "INT8 x INT8  ->  INT32 acc.",
            ha="center", va="center", fontsize=5.7, color=INK,
            fontweight="bold", zorder=8)


def draw_pe_inset(ax):
    """Show the mode-select arithmetic datapath inside one array PE."""
    x, y, w, h = 0.342, 0.100, 0.318, 0.160
    rounded_box(ax, x, y, w, h, "", (), "#EEF3F5",
                title_size=6.2, lw=0.9, radius=0.009)
    ax.text(x + w / 2, y + h - 0.018, "PE micro-architecture",
            ha="center", va="top", fontsize=6.2, fontweight="bold",
            color=NAVY, zorder=8)
    ax.text(x + w / 2, y + h - 0.041,
            "registered inputs / mode-select / registered result",
            ha="center", va="center", fontsize=5.0, color=MUTED, zorder=8)

    def mini_box(mx, my, mw, mh, title, lines, fill=PAPER, edge=NAVY):
        ax.add_patch(FancyBboxPatch(
            (mx, my), mw, mh,
            boxstyle="round,pad=0.002,rounding_size=0.005",
            linewidth=0.65, edgecolor=edge, facecolor=fill, zorder=7,
        ))
        ax.text(mx + mw / 2, my + mh - 0.017, title,
                ha="center", va="top", fontsize=5.0, fontweight="bold",
                color=NAVY, zorder=8)
        for idx, line in enumerate(lines):
            ax.text(mx + mw / 2, my + mh - 0.034 - idx * 0.017, line,
                    ha="center", va="top", fontsize=5.0, color=INK,
                    zorder=8)

    mini_box(x + 0.010, y + 0.045, 0.073, 0.070, "PE regs",
             ("a,b: 16b", "s: 16b / sh: 6b"), fill="#F7FBFC")
    mini_box(x + 0.096, y + 0.038, 0.134, 0.080, "mode-select arithmetic",
             ("MAC/HOLD: acc+a*b", "SUB / MAX / ADD", "SCALE: a*s >> sh"),
             fill="#E2EEF5", edge=DATA)
    mini_box(x + 0.243, y + 0.045, 0.065, 0.070, "PE out",
             ("result: 32b", "acc: 32b"), fill="#F7FBFC")
    arrow(ax, (x + 0.083, y + 0.080), (x + 0.096, y + 0.080),
          color=DATA, lw=0.9, mutation=6, zorder=9)
    arrow(ax, (x + 0.230, y + 0.080), (x + 0.243, y + 0.080),
          color=DATA, lw=0.9, mutation=6, zorder=9)


def draw_control_plane(ax):
    rounded_box(ax, 0.177, 0.838, 0.784, 0.132, "", (), CONTROL_FILL,
                edge=GRID, lw=0.8, radius=0.010)
    ax.text(0.190, 0.954, "CONTROL PLANE", ha="left", va="top",
            fontsize=5.5, fontweight="bold", color=MUTED, zorder=7)
    rounded_box(ax, 0.206, 0.865, 0.125, 0.070, "Register file", (), PAPER,
                edge=CONTROL, title_size=6.1, lw=0.8, radius=0.008)
    rounded_box(ax, 0.357, 0.865, 0.290, 0.070, "Tile scheduler FSM", (), PAPER,
                edge=CONTROL, title_size=6.1, lw=0.8, radius=0.008)
    rounded_box(ax, 0.673, 0.865, 0.146, 0.070, "Perf. / error", (), PAPER,
                edge=CONTROL, title_size=6.1, lw=0.8, radius=0.008)
    arrow(ax, (0.331, 0.900), (0.357, 0.900), color=CONTROL, lw=1.0,
          mutation=7, zorder=7)
    arrow(ax, (0.647, 0.900), (0.673, 0.900), color=CONTROL, lw=1.0,
          mutation=7, zorder=7)
    ax.text(0.502, 0.876, "LOAD_Q -> LOAD_KV -> QK -> SOFTMAX -> PV -> WRITEBACK",
            ha="center", va="center", fontsize=5.0, color=MUTED, zorder=8)


def render(output_dir):
    mpl.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["Arial", "Helvetica", "Liberation Sans", "DejaVu Sans"],
        "font.size": 6.0,
        "axes.linewidth": 0.0,
        "svg.fonttype": "none",
        "pdf.fonttype": 42,
        "pdf.use14corefonts": False,
        "savefig.facecolor": PAPER,
    })

    fig = plt.figure(figsize=(FIG_W, FIG_H), facecolor=PAPER)
    ax = fig.add_axes([0, 0, 1, 1])
    ax.set_xlim(0, 1)
    ax.set_ylim(0, 1)
    ax.axis("off")

    # Accelerator boundary and external interfaces.
    ax.add_patch(FancyBboxPatch(
        (0.151, 0.090), 0.810, 0.730,
        boxstyle="round,pad=0.006,rounding_size=0.014",
        linewidth=0.8, edgecolor=GRID, facecolor=CHIP_FILL, zorder=1,
    ))
    ax.text(0.165, 0.806, "FLASHATTENTION ACCELERATOR DATA PLANE",
            ha="left", va="top", fontsize=5.7, fontweight="bold",
            color=MUTED, zorder=7)

    rounded_box(ax, 0.018, 0.838, 0.112, 0.132, "Host CPU", ("AXI4-Lite", "32-bit"),
                CONTROL_FILL, title_size=6.8)
    draw_control_plane(ax)
    arrow(ax, (0.130, 0.900), (0.206, 0.900), color=CONTROL, lw=1.05,
          mutation=7, zorder=7)

    rounded_box(ax, 0.018, 0.365, 0.112, 0.225, "DMA / tile loader",
                ("128-bit input", "Q, K, V tiles", "2 beats / word"),
                MEM_FILL, title_size=6.7)
    rounded_box(ax, 0.018, 0.180, 0.112, 0.105, "Off-chip DRAM", (),
                CONTROL_FILL, title_size=6.7)
    arrow(ax, (0.074, 0.285), (0.074, 0.365), color=DATA, lw=1.2,
          mutation=8)
    draw_cache(ax)
    arrow(ax, (0.130, 0.478), (0.177, 0.478), color=DATA, lw=1.45,
          mutation=8)
    label(ax, 0.153, 0.501, "128 bit")
    label(ax, 0.153, 0.455, "assemble 2:1", size=5.0)

    # Phase-specific stream formation feeding a physically shared array.
    rounded_box(ax, 0.365, 0.594, 0.075, 0.115, "QK phase",
                ("Q x K^T", "tile stream"), COMPUTE_FILL,
                title_size=6.2, body_size=5.1)
    rounded_box(ax, 0.365, 0.322, 0.075, 0.115, "PV phase",
                ("beta x V", "2 feature halves"), COMPUTE_FILL,
                title_size=6.2, body_size=5.1)
    arrow(ax, (0.332, 0.620), (0.365, 0.650), color=DATA, lw=1.35,
          mutation=8)
    label(ax, 0.345, 0.649, "Q, K", size=5.0)
    poly_arrow(ax, [(0.332, 0.348), (0.347, 0.348), (0.347, 0.380),
                    (0.365, 0.380)], color=DATA, lw=1.35, mutation=8)
    label(ax, 0.344, 0.327, "V", size=5.0)
    arrow(ax, (0.440, 0.650), (0.465, 0.650), color=DATA, lw=1.35,
          mutation=8)
    arrow(ax, (0.440, 0.380), (0.465, 0.380), color=DATA, lw=1.35,
          mutation=8)

    draw_array(ax)

    rounded_box(ax, 0.676, 0.468, 0.151, 0.300, "Online softmax",
                ("scale + causal mask", "row max + PWL exp", "row sum / LSE update",
                 "state: m, l", "emit: alpha, beta"), SOFTMAX_FILL,
                title_size=7.3, body_size=5.5)
    arrow(ax, (0.641, 0.650), (0.676, 0.650), color=DATA, lw=1.45,
          mutation=8)
    label(ax, 0.658, 0.674, "score tile", size=5.0)

    rounded_box(ax, 0.676, 0.205, 0.151, 0.170, "Output accumulator",
                ("row buffer", "INT32 O_acc", "alpha rescale"), OUTPUT_FILL,
                title_size=6.9, body_size=5.4)
    poly_arrow(ax, [(0.641, 0.335), (0.658, 0.335), (0.658, 0.290),
                    (0.676, 0.290)], color=DATA, lw=1.45, mutation=8)
    label(ax, 0.655, 0.311, "PV", size=5.0)

    # Online-state feedback remains inside the tile loop.
    poly_arrow(ax, [(0.706, 0.468), (0.706, 0.424), (0.615, 0.424),
                    (0.615, 0.447), (0.440, 0.397)],
               color=STATE, lw=1.35, mutation=8)
    label(ax, 0.594, 0.444, "beta tile (32 x 32, INT16)",
          color=STATE, size=5.0)
    poly_arrow(ax, [(0.750, 0.468), (0.750, 0.411), (0.808, 0.411),
                    (0.808, 0.375)], color=STATE, lw=1.35, mutation=8)
    label(ax, 0.783, 0.430, "alpha", color=STATE, size=5.0)
    poly_arrow(ax, [(0.676, 0.238), (0.665, 0.238), (0.665, 0.292),
                    (0.602, 0.292), (0.580, 0.285)],
               color=STATE, lw=1.25, mutation=8)
    arrow(ax, (0.805, 0.730), (0.805, 0.754), color=STATE, lw=1.2,
          mutation=7, rad=1.2)
    label(ax, 0.831, 0.747, "m, l", color=STATE, size=5.0)

    rounded_box(ax, 0.852, 0.454, 0.090, 0.205, "Finalize",
                ("reciprocal LUT", "O_acc / l", "requantize", "INT8 output"),
                OUTPUT_FILL, title_size=6.7, body_size=5.2)
    arrow(ax, (0.827, 0.596), (0.852, 0.596), color=STATE, lw=1.2,
          mutation=8)
    label(ax, 0.840, 0.616, "l", color=STATE, size=5.0)
    poly_arrow(ax, [(0.827, 0.290), (0.842, 0.290), (0.842, 0.519),
                    (0.852, 0.519)], color=DATA, lw=1.35, mutation=8)

    rounded_box(ax, 0.852, 0.205, 0.090, 0.135, "AXI4 write",
                ("128-bit", "2 beats / row"), MEM_FILL,
                title_size=6.5, body_size=5.3)
    arrow(ax, (0.897, 0.454), (0.897, 0.340), color=DATA, lw=1.35,
          mutation=8)
    poly_arrow(ax, [(0.852, 0.080), (0.132, 0.080), (0.132, 0.232),
                    (0.130, 0.232)], color=DATA, lw=1.15, mutation=8)
    label(ax, 0.497, 0.096, "normalized output", size=5.0)

    # Scheduler fan-out; dashed arrows carry control only.
    for target_x, target_y in [(0.255, 0.760), (0.403, 0.709),
                               (0.552, 0.730), (0.751, 0.768),
                               (0.897, 0.659)]:
        poly_arrow(ax, [(0.500, 0.865), (0.500, 0.828),
                        (target_x, 0.828), (target_x, target_y)],
                   color=CONTROL, lw=0.85, style="--", mutation=6, zorder=3)

    draw_pe_inset(ax)

    # Bottom publication key and implementation note.
    ax.add_patch(FancyBboxPatch(
        (0.151, 0.012), 0.810, 0.058,
        boxstyle="round,pad=0.004,rounding_size=0.010",
        linewidth=0.6, edgecolor=GRID, facecolor="#F8F9FA", zorder=2,
    ))
    ax.text(0.168, 0.052, "ON-CHIP TILE LOOP", ha="left", va="center",
            fontsize=5.4, fontweight="bold", color=NAVY, zorder=7)
    ax.text(0.168, 0.029, "No off-chip score / probability materialization",
            ha="left", va="center", fontsize=5.2, color=INK, zorder=7)
    ax.text(0.450, 0.052, "MEMORY MAPPING", ha="left", va="center",
            fontsize=5.4, fontweight="bold", color=NAVY, zorder=7)
    ax.text(0.450, 0.029, "ASIC: banked SRAM macros   |   FPGA: URAM / BRAM",
            ha="left", va="center", fontsize=5.2, color=INK, zorder=7)
    ax.plot([0.775, 0.807], [0.052, 0.052], color=DATA, linewidth=1.5,
            zorder=7)
    ax.text(0.814, 0.052, "data", ha="left", va="center", fontsize=5.0,
            color=MUTED, zorder=7)
    ax.plot([0.775, 0.807], [0.029, 0.029], color=STATE, linewidth=1.5,
            zorder=7)
    ax.text(0.814, 0.029, "online state", ha="left", va="center",
            fontsize=5.0, color=MUTED, zorder=7)
    ax.plot([0.884, 0.916], [0.052, 0.052], color=CONTROL, linewidth=1.1,
            linestyle="--", zorder=7)
    ax.text(0.923, 0.052, "control", ha="left", va="center", fontsize=5.0,
            color=MUTED, zorder=7)

    output_dir.mkdir(parents=True, exist_ok=True)
    stem = output_dir / "flash_attention_accelerator_architecture"
    fig.savefig(str(stem) + ".svg", format="svg")
    fig.savefig(str(stem) + ".pdf", format="pdf")
    fig.savefig(str(stem) + ".png", format="png", dpi=600)
    fig.savefig(str(stem) + ".tiff", format="tiff", dpi=600,
                pil_kwargs={"compression": "tiff_lzw"})
    plt.close(fig)

    expected_pixels = (round(FIG_W * 600), round(FIG_H * 600))
    png_size = Image.open(str(stem) + ".png").size
    tiff_size = Image.open(str(stem) + ".tiff").size
    svg_root = ET.parse(str(stem) + ".svg").getroot()
    svg_text_nodes = sum(1 for node in svg_root.iter()
                         if node.tag.endswith("text"))
    assert png_size == expected_pixels, (png_size, expected_pixels)
    assert tiff_size == expected_pixels, (tiff_size, expected_pixels)
    assert svg_text_nodes > 0, "SVG export contains no editable text nodes"
    print("Visual QA: PNG/TIFF={} px; SVG text nodes={}".format(
        expected_pixels, svg_text_nodes))


if __name__ == "__main__":
    render(Path(__file__).resolve().parent)
