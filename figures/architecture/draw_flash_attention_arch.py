#!/usr/bin/env python3
"""Render the final FlashAttention accelerator architecture at IEEE double-column width."""

from pathlib import Path
import xml.etree.ElementTree as ET

import matplotlib as mpl
from PIL import Image

mpl.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch, Rectangle


FIG_WIDTH_MM = 183.0
FIG_HEIGHT_MM = 112.0
FIG_W = FIG_WIDTH_MM / 25.4
FIG_H = FIG_HEIGHT_MM / 25.4

INK = "#202124"
MID = "#5F6368"
GRID = "#9AA0A6"
WHITE = "#FFFFFF"
PALE = "#F7F8FA"
CONTROL = "#C62828"
CONTROL_FILL = "#FCE8E6"
COMPUTE = "#2455D6"
COMPUTE_FILL = "#E8EEFF"
NONLINEAR = "#147D3F"
NONLINEAR_FILL = "#E7F4EA"
STATE = "#743AB2"
STATE_FILL = "#F1E8F8"
MEMORY = "#4F6367"
MEMORY_FILL = "#EEF1F2"
GOLD = "#A66A00"
GOLD_FILL = "#FFF4D6"


def box(ax, x, y, w, h, title="", subtitle="", fill=WHITE, edge=INK,
        lw=0.8, title_color=INK, title_size=6.1, subtitle_size=5.0,
        radius=0.002, zorder=4):
    patch = FancyBboxPatch(
        (x, y), w, h,
        boxstyle=f"round,pad=0.0025,rounding_size={radius}",
        facecolor=fill, edgecolor=edge, linewidth=lw, zorder=zorder,
    )
    ax.add_patch(patch)
    if title:
        ax.text(x + w / 2, y + h - 0.014, title, ha="center", va="top",
                fontsize=title_size, fontweight="bold", color=title_color,
                zorder=zorder + 1)
    if subtitle:
        ax.text(x + w / 2, y + 0.014, subtitle, ha="center", va="bottom",
                fontsize=subtitle_size, color=MID, linespacing=1.12,
                zorder=zorder + 1)
    return patch


def arrow(ax, x0, y0, x1, y1, color=INK, lw=1.0, mutation=6.5,
          linestyle="-", zorder=9, connection="arc3,rad=0"):
    patch = FancyArrowPatch(
        (x0, y0), (x1, y1), arrowstyle="-|>", mutation_scale=mutation,
        linewidth=lw, color=color, linestyle=linestyle,
        connectionstyle=connection, shrinkA=0, shrinkB=0, zorder=zorder,
    )
    ax.add_patch(patch)
    return patch


def poly_arrow(ax, points, color=INK, lw=1.0, mutation=6.5,
               linestyle="-", zorder=9):
    for p0, p1 in zip(points[:-2], points[1:-1]):
        ax.plot([p0[0], p1[0]], [p0[1], p1[1]], color=color,
                linewidth=lw, linestyle=linestyle, zorder=zorder)
    return arrow(ax, *points[-2], *points[-1], color=color, lw=lw,
                 mutation=mutation, linestyle=linestyle, zorder=zorder)


def tag(ax, x, y, text, color=INK, size=5.0, weight="normal",
        ha="center", va="center", rotation=0, zorder=14):
    ax.text(x, y, text, ha=ha, va=va, rotation=rotation, fontsize=size,
            fontweight=weight, color=color,
            bbox=dict(facecolor=WHITE, edgecolor="none", pad=0.45, alpha=0.94),
            zorder=zorder)


def phase_badge(ax, x, y, number, text, color):
    ax.text(x, y, number, ha="center", va="center", fontsize=5.0,
            fontweight="bold", color=WHITE,
            bbox=dict(boxstyle="circle,pad=0.19", facecolor=color,
                      edgecolor=color, linewidth=0.5), zorder=15)
    ax.text(x + 0.014, y, text, ha="left", va="center", fontsize=5.0,
            fontweight="bold", color=color, zorder=15)


def mini_box(ax, x, y, w, h, text, edge, fill=WHITE, size=5.0,
             weight="normal", zorder=7):
    ax.add_patch(Rectangle((x, y), w, h, facecolor=fill, edgecolor=edge,
                           linewidth=0.58, zorder=zorder))
    ax.text(x + w / 2, y + h / 2, text, ha="center", va="center",
            fontsize=size, fontweight=weight, color=INK, linespacing=1.08,
            zorder=zorder + 1)


def draw_system_band(ax):
    box(ax, 0.018, 0.830, 0.135, 0.145, "Host / PS",
        "AXI4-Lite control\n128-bit AXI data", fill=CONTROL_FILL,
        edge=CONTROL, title_color=CONTROL, title_size=6.5)

    box(ax, 0.166, 0.830, 0.292, 0.145, "Q / K / V Ping-Pong Cache", "",
        fill=MEMORY_FILL, edge=MEMORY, title_color=MEMORY, title_size=6.5)
    cache_specs = [
        ("Q", "row stream", COMPUTE),
        ("K", "key-major", COMPUTE),
        ("V", "feature-major", STATE),
    ]
    for idx, (name, layout, color) in enumerate(cache_specs):
        cx = 0.179 + idx * 0.088
        mini_box(ax, cx, 0.855, 0.078, 0.061, f"{name}  P0 | P1\n{layout}",
                 color, WHITE, size=5.0, weight="bold")
    ax.text(0.312, 0.933, "256-bit word = 32 x INT8",
            ha="center", va="center", fontsize=5.0, color=MID, zorder=8)
    ax.text(0.410, 0.842, "V[d] = V[0:31,d]", ha="center", va="center",
            fontsize=5.0, color=STATE, fontweight="bold", zorder=8)

    box(ax, 0.471, 0.830, 0.235, 0.145, "Top Controller",
        "tile scheduler | phase control | counters", fill=CONTROL_FILL,
        edge=CONTROL, title_color=CONTROL, title_size=6.5)
    states = ["LOAD", "QK", "SMX", "WS-PV", "NORM"]
    widths = [0.034, 0.034, 0.034, 0.046, 0.042]
    sx = 0.487
    for idx, (state, sw) in enumerate(zip(states, widths)):
        mini_box(ax, sx, 0.866, sw, 0.035, state, CONTROL, WHITE,
                 size=5.0, weight="bold")
        if idx < len(states) - 1:
            arrow(ax, sx + sw, 0.8835, sx + sw + 0.008, 0.8835,
                  color=CONTROL, lw=0.6, mutation=4.2)
        sx += sw + 0.008

    box(ax, 0.719, 0.830, 0.263, 0.145, "Online O Storage + Output", "",
        fill=STATE_FILL, edge=STATE, title_color=STATE, title_size=6.5)
    mini_box(ax, 0.735, 0.865, 0.080, 0.047, "row-major\nINT32 O buffer",
             STATE, WHITE, size=5.0, weight="bold")
    mini_box(ax, 0.827, 0.842, 0.059, 0.038, "alpha rescale\nfeedback",
             STATE, WHITE, size=5.0, weight="bold")
    mini_box(ax, 0.901, 0.865, 0.065, 0.047, "normalize\n+ AXI WB",
             STATE, WHITE, size=5.0, weight="bold")
    arrow(ax, 0.815, 0.897, 0.901, 0.897, color=STATE, lw=0.75, mutation=4.8)
    poly_arrow(ax, [(0.815, 0.880), (0.821, 0.880), (0.821, 0.861),
                    (0.827, 0.861)], color=STATE, lw=0.68, mutation=4.5)

    arrow(ax, 0.153, 0.903, 0.166, 0.903, color=MEMORY, lw=1.0)
    tag(ax, 0.159, 0.922, "128b", color=MEMORY, size=5.0)

    ax.add_patch(Rectangle((0.018, 0.787), 0.964, 0.026,
                           facecolor=WHITE, edgecolor=INK,
                           linewidth=0.72, zorder=5))
    ax.text(0.500, 0.800, "REGISTERED LOCAL INTERCONNECT / PHASE CONTROL",
            ha="center", va="center", fontsize=5.25, fontweight="bold",
            color=INK, zorder=7)
    arrow(ax, 0.085, 0.830, 0.085, 0.813, color=CONTROL, lw=0.8,
          linestyle="--", mutation=5.2)
    arrow(ax, 0.312, 0.830, 0.312, 0.813, color=MEMORY, lw=1.0, mutation=5.2)
    arrow(ax, 0.589, 0.830, 0.589, 0.813, color=CONTROL, lw=0.8,
          linestyle="--", mutation=5.2)
    arrow(ax, 0.850, 0.813, 0.850, 0.830, color=STATE, lw=1.0, mutation=5.2)


def draw_front_end(ax):
    box(ax, 0.018, 0.365, 0.188, 0.382, "Stream Front End",
        "bounded registered interfaces", fill=MEMORY_FILL, edge=MEMORY,
        title_color=MEMORY, title_size=6.3)
    box(ax, 0.037, 0.635, 0.150, 0.075, "FSA QK Engine",
        "Q rows + K columns", fill=WHITE, edge=COMPUTE,
        title_color=COMPUTE, title_size=5.55, subtitle_size=5.0)
    box(ax, 0.037, 0.533, 0.150, 0.075, "Registered Skew",
        "Q row | K/V column | O seed", fill=WHITE, edge=MEMORY,
        title_color=MEMORY, title_size=5.55, subtitle_size=5.0)
    box(ax, 0.037, 0.431, 0.150, 0.075, "FSA PV Engine",
        "V[:,d] issue + row preload", fill=WHITE, edge=STATE,
        title_color=STATE, title_size=5.55, subtitle_size=5.0)
    arrow(ax, 0.187, 0.469, 0.222, 0.469, color=STATE, lw=1.15,
          mutation=6.0)
    poly_arrow(ax, [(0.312, 0.787), (0.312, 0.766), (0.112, 0.766),
                    (0.112, 0.710)], color=MEMORY, lw=0.95, mutation=5.5)


def draw_array(ax):
    x, y, w, h = 0.222, 0.365, 0.530, 0.382
    box(ax, x, y, w, h, "Fused FSA Array (32 x 32 PEs)",
        "4 physical stripes x 8 rows | P stationary in PE",
        fill=COMPUTE_FILL, edge=COMPUTE, title_color=COMPUTE,
        title_size=6.85, subtitle_size=5.0, lw=1.05)

    gx, gy = x + 0.063, y + 0.061
    gw, gh = w - 0.112, h - 0.121
    rows, cols = 8, 8
    cw, ch = gw / cols, gh / rows
    for rr in range(rows):
        stripe_fill = "#DDE6FF" if (rr // 2) % 2 == 0 else "#EEF2FF"
        for cc in range(cols):
            ax.add_patch(Rectangle((gx + cc * cw, gy + rr * ch), cw, ch,
                                   facecolor=stripe_fill, edgecolor="#7892D8",
                                   linewidth=0.40, zorder=6))
    hi_r, hi_c = 3, 4
    ax.add_patch(Rectangle((gx + hi_c * cw, gy + hi_r * ch), cw, ch,
                           facecolor="#C9D6FF", edgecolor=COMPUTE,
                           linewidth=1.0, zorder=7))
    ax.text(gx + (hi_c + 0.5) * cw, gy + (hi_r + 0.5) * ch, "PE",
            ha="center", va="center", fontsize=5.0, fontweight="bold",
            color=COMPUTE, zorder=8)

    # Sparse P markers emphasize stationarity without obscuring the fabric.
    for rr, cc in ((1, 1), (2, 5), (6, 2), (6, 6)):
        ax.text(gx + (cc + 0.5) * cw, gy + (rr + 0.5) * ch, "P",
                ha="center", va="center", fontsize=5.0, fontweight="bold",
                color=STATE, alpha=0.80, zorder=8)

    # Boundary streams.
    arrow(ax, 0.187, 0.675, gx - 0.008, 0.675,
          color=COMPUTE, lw=1.25, mutation=6.5)
    tag(ax, 0.235, 0.695, "Q rows (QK only)", color=COMPUTE,
        size=5.0, ha="left")
    arrow(ax, gx + gw * 0.32, y + h - 0.054,
          gx + gw * 0.32, gy + gh + 0.004,
          color=COMPUTE, lw=1.25, mutation=6.5)
    tag(ax, gx + gw * 0.32, gy + gh + 0.015, "K columns",
        color=COMPUTE, size=5.0)
    arrow(ax, gx + gw * 0.72, y + h - 0.054,
          gx + gw * 0.72, gy + gh + 0.004,
          color=STATE, lw=1.25, mutation=6.5)
    tag(ax, gx + gw * 0.72, gy + gh + 0.015, "V[:,d] columns",
        color=STATE, size=5.0)

    # Phase-exclusive nearest-neighbor row links.
    y_max = gy + gh * 0.79
    y_delta = gy + gh * 0.58
    y_sum = gy + gh * 0.25
    arrow(ax, gx + 0.012, y_max, gx + gw - 0.010, y_max,
          color=CONTROL, lw=1.08, mutation=6.5)
    arrow(ax, gx + gw - 0.010, y_delta, gx + 0.012, y_delta,
          color=STATE, lw=1.08, mutation=6.5)
    arrow(ax, gx + gw - 0.010, y_sum + 0.006, gx + 0.012, y_sum + 0.006,
          color=NONLINEAR, lw=1.00, mutation=6.2)
    arrow(ax, gx + 0.012, y_sum - 0.006, gx + gw - 0.010, y_sum - 0.006,
          color=GOLD, lw=1.00, mutation=6.2)
    tag(ax, gx + gw * 0.52, y_max + 0.016, "staggered rowmax  ->",
        color=CONTROL, size=5.0)
    tag(ax, gx + gw * 0.50, y_delta - 0.016, "<-  m_new | score - m_new",
        color=STATE, size=5.0)
    tag(ax, gx + gw * 0.52, y_sum + 0.020,
        "<- rowsum  |  WS partial sum ->", color=NONLINEAR, size=5.0)
    tag(ax, gx + gw * 0.50, gy + 0.014, "prob_q holds P across 64 continuous features",
        color=STATE, size=5.0, weight="bold")

    # Four stripe-local row-buffer banks, kept beside their owning rows.
    bx = gx + gw + 0.012
    for stripe in range(4):
        by = gy + stripe * gh / 4 + 0.005
        ax.add_patch(Rectangle((bx, by), 0.027, gh / 4 - 0.010,
                               facecolor=GOLD_FILL, edgecolor=GOLD,
                               linewidth=0.52, zorder=7))
        ax.text(bx + 0.0135, by + (gh / 4 - 0.010) / 2, "2x\nO row",
                ha="center", va="center", fontsize=5.0, fontweight="bold",
                color=GOLD, linespacing=0.90, zorder=8)
    # Representative PE connector.
    hx = gx + (hi_c + 0.5) * cw
    hy = gy + hi_r * ch
    poly_arrow(ax, [(hx, hy), (hx, y - 0.012), (0.292, y - 0.012),
                    (0.292, 0.322)], color=COMPUTE, lw=0.7,
               linestyle="--", mutation=4.7, zorder=5)


def draw_side_units(ax):
    box(ax, 0.768, 0.365, 0.214, 0.382, "Array-Side Units",
        "no score / probability tile buffer", fill=PALE, edge=INK,
        title_size=6.3)
    box(ax, 0.786, 0.638, 0.178, 0.071, "32-Lane Scale + PWL Exp",
        "only nonlinear datapath", fill=NONLINEAR_FILL, edge=NONLINEAR,
        title_color=NONLINEAR, title_size=5.45, subtitle_size=5.0)
    box(ax, 0.786, 0.537, 0.178, 0.071, "Row State (m, l, alpha)",
        "online update | 32 rows", fill=STATE_FILL, edge=STATE,
        title_color=STATE, title_size=5.45, subtitle_size=5.0)
    box(ax, 0.786, 0.436, 0.178, 0.071, "Row Result Interface",
        "completed 32-feature half", fill=GOLD_FILL, edge=GOLD,
        title_color=GOLD, title_size=5.45, subtitle_size=5.0)

    # Delta leaves the array; probability returns to its originating PE.
    arrow(ax, 0.752, 0.677, 0.786, 0.677, color=NONLINEAR, lw=1.1)
    arrow(ax, 0.786, 0.660, 0.752, 0.660, color=NONLINEAR, lw=1.1)
    tag(ax, 0.768, 0.698, "32 rows / column", color=NONLINEAR, size=5.0)
    arrow(ax, 0.752, 0.574, 0.786, 0.574, color=STATE, lw=1.0)
    arrow(ax, 0.786, 0.557, 0.752, 0.557, color=STATE, lw=1.0)
    arrow(ax, 0.752, 0.472, 0.786, 0.472, color=GOLD, lw=1.0)

    poly_arrow(ax, [(0.964, 0.472), (0.974, 0.472), (0.974, 0.820),
                    (0.775, 0.820), (0.775, 0.865)],
               color=STATE, lw=1.0, mutation=5.5)
    poly_arrow(ax, [(0.857, 0.842), (0.857, 0.820), (0.737, 0.820),
                    (0.737, 0.439)], color=STATE, lw=0.9,
               linestyle="--", mutation=5.2)

    phase_badge(ax, 0.233, 0.765, "1", "QK + ROWMAX", COMPUTE)
    phase_badge(ax, 0.425, 0.765, "2", "DELTA + EXP", STATE)
    phase_badge(ax, 0.603, 0.765, "3", "ROWSUM + STATE", NONLINEAR)
    phase_badge(ax, 0.804, 0.765, "4", "WS-PV + O UPDATE", GOLD)


def draw_pe_panel(ax):
    x, y, w, h = 0.018, 0.027, 0.575, 0.290
    box(ax, x, y, w, h, "Representative PE: Phase-Multiplexed Datapath",
        "registered nearest-neighbor links; P remains stationary",
        fill=WHITE, edge=INK, title_size=6.15, subtitle_size=5.0)

    box(ax, 0.036, 0.091, 0.101, 0.143, "Systolic I/O",
        "Q ->\nK / V down\nvalid + last", fill=MEMORY_FILL, edge=MEMORY,
        title_color=MEMORY, title_size=5.15, subtitle_size=5.0)

    box(ax, 0.158, 0.073, 0.206, 0.179, "Mode-Selected Arithmetic", "",
        fill=COMPUTE_FILL, edge=COMPUTE, title_color=COMPUTE,
        title_size=5.35)
    ops = [
        ("QK MAC", "accum + Q*K", COMPUTE, "#F6F8FF"),
        ("MAX", "max(score, pass)", CONTROL, "#FFF5F4"),
        ("SUB", "score - m_new", STATE, "#FAF5FE"),
        ("ROWSUM", "sum + P", NONLINEAR, "#F3FBF5"),
        ("WS MAC", "sum + P*V", GOLD, "#FFF9EA"),
    ]
    for idx, (name, desc, color, fill) in enumerate(ops):
        oy = 0.194 - idx * 0.030
        ax.add_patch(Rectangle((0.171, oy), 0.180, 0.024,
                               facecolor=fill, edgecolor=color,
                               linewidth=0.52, zorder=7))
        ax.text(0.178, oy + 0.012, name, ha="left", va="center",
                fontsize=5.0, fontweight="bold", color=color, zorder=8)
        ax.text(0.343, oy + 0.012, desc, ha="right", va="center",
                fontsize=5.0, color=INK, zorder=8)

    box(ax, 0.385, 0.073, 0.091, 0.179, "Local State", "",
        fill=STATE_FILL, edge=STATE, title_color=STATE, title_size=5.25)
    mini_box(ax, 0.397, 0.164, 0.067, 0.044, "accum_q\nscore / delta",
             STATE, WHITE, size=5.0, weight="bold")
    mini_box(ax, 0.397, 0.105, 0.067, 0.044, "prob_q\nstationary P",
             STATE, WHITE, size=5.0, weight="bold")

    box(ax, 0.497, 0.073, 0.078, 0.179, "Row Links", "",
        fill=NONLINEAR_FILL, edge=NONLINEAR, title_color=NONLINEAR,
        title_size=5.25)
    links = [
        (0.190, "max ->", CONTROL),
        (0.156, "<- m_new", STATE),
        (0.122, "<- sum", NONLINEAR),
        (0.088, "WS sum ->", GOLD),
    ]
    for yy, text, color in links:
        ax.text(0.536, yy, text, ha="center", va="center", fontsize=5.0,
                fontweight="bold", color=color, zorder=8)

    arrow(ax, 0.137, 0.161, 0.158, 0.161, color=COMPUTE, lw=0.9, mutation=5.0)
    arrow(ax, 0.364, 0.161, 0.385, 0.161, color=COMPUTE, lw=0.9, mutation=5.0)
    arrow(ax, 0.476, 0.161, 0.497, 0.161, color=STATE, lw=0.9, mutation=5.0)


def draw_online_o_panel(ax):
    x, y, w, h = 0.610, 0.027, 0.372, 0.290
    box(ax, x, y, w, h, "Stripe-Local Online O Update",
        "two 1024-bit half buffers per active row",
        fill=WHITE, edge=INK, title_size=6.15, subtitle_size=5.0)

    mini_box(ax, 0.627, 0.185, 0.061, 0.051, "both O halves\nfrom SRAM", STATE,
             STATE_FILL, size=5.0, weight="bold")
    mini_box(ax, 0.706, 0.185, 0.061, 0.051, "32-lane\nalpha x O", STATE,
             WHITE, size=5.0, weight="bold")
    mini_box(ax, 0.785, 0.174, 0.074, 0.073, "DUAL BUFFERS\nB0: seed/result\nB1: seed/result",
             GOLD, GOLD_FILL, size=5.0, weight="bold")
    mini_box(ax, 0.883, 0.185, 0.075, 0.051, "PE row\nsum + P x V",
             COMPUTE, COMPUTE_FILL, size=5.0, weight="bold")
    arrow(ax, 0.688, 0.210, 0.706, 0.210, color=STATE, lw=0.9, mutation=5.0)
    arrow(ax, 0.767, 0.210, 0.785, 0.210, color=STATE, lw=0.9, mutation=5.0)
    arrow(ax, 0.859, 0.210, 0.883, 0.210, color=GOLD, lw=0.9, mutation=5.0)
    poly_arrow(ax, [(0.921, 0.185), (0.921, 0.158), (0.822, 0.158),
                    (0.822, 0.174)], color=GOLD, lw=0.9, mutation=5.0)
    tag(ax, 0.872, 0.147, "right-edge results", color=GOLD, size=5.0)

    ax.text(0.796, 0.116, "O_j = alpha_j O_(j-1) + P_j V_j",
            ha="center", va="center", fontsize=5.35, fontweight="bold",
            color=INK, zorder=8)
    ax.text(0.796, 0.087,
            "64 V features issued continuously  |  one array drain",
            ha="center", va="center", fontsize=5.0, color=MID, zorder=8)


def validate_outputs(output_dir):
    stem = output_dir / "flash_attention_accelerator_architecture"
    png_path = stem.with_suffix(".png")
    tiff_path = stem.with_suffix(".tiff")
    svg_path = stem.with_suffix(".svg")
    svg_text = svg_path.read_text(encoding="utf-8")
    svg_path.write_text("\n".join(line.rstrip() for line in svg_text.splitlines()) + "\n",
                        encoding="utf-8")
    expected_px = (int(FIG_W * 600), int(FIG_H * 600))
    for raster_path in (png_path, tiff_path):
        with Image.open(raster_path) as image:
            if image.size != expected_px:
                raise RuntimeError(
                    f"{raster_path.suffix} size {image.size} != expected {expected_px}"
                )
            if image.getbbox() is None:
                raise RuntimeError(f"{raster_path.suffix} render is blank")
    root = ET.parse(svg_path).getroot()
    if not any(element.tag.endswith("text") for element in root.iter()):
        raise RuntimeError("SVG text is not editable")


def render(output_dir):
    mpl.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["Arial", "Helvetica", "Liberation Sans", "DejaVu Sans"],
        "font.size": 6.0,
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

    draw_system_band(ax)
    draw_front_end(ax)
    draw_array(ax)
    draw_side_units(ax)
    draw_pe_panel(ax)
    draw_online_o_panel(ax)

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
