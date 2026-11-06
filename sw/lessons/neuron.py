"""Manim video: one neuron of the card's network, on test image #0.

    ~/fpga/venv-manim/bin/manim -qh sw/lessons/neuron.py OneNeuron

Uses the real data: the card's model (build/mnist/model.bin) and the test
image, and the card's arithmetic (sw/npu/npu_ref.py). Text only, no LaTeX, so
it renders with Manim alone. Narration script: sw/lessons/README.md.
"""
import gzip
import os
import struct

import numpy as np
from manim import (Group, DOWN, LEFT, RIGHT, UP, UL, ORIGIN, Create, FadeIn, FadeOut, ImageMobject, Line, Rectangle,
                   Scene, SurroundingRectangle, Text, Transform, ValueTracker, VGroup, Write, always_redraw,
                   config, linear, smooth)
from manim import RESAMPLING_ALGORITHMS

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
BG, INK, MUTED, BLUE, RED, YELLOW, GREEN = "#0b1017", "#e8eef4", "#93a2b1", "#58c4dd", "#fc6255", "#f4d35e", "#83c167"
MONO = "JetBrainsMono Nerd Font"
config.background_color = BG


def load():
    with open(os.path.join(ROOT, "build", "mnist", "model.bin"), "rb") as f:
        hdr = struct.unpack("<8I", f.read(40)[8:])
        k1, n1 = hdr[0], hdr[1]
        w1t = np.frombuffer(f.read(n1 * k1), np.int8).reshape(n1, k1)
        b1 = np.frombuffer(f.read(n1 * 4), np.int32)
    mult, shift = hdr[5], hdr[6]
    img = np.frombuffer(gzip.open(os.path.join(ROOT, "build", "mnist", "t10k-images-idx3-ubyte.gz")).read(), np.uint8, offset=16)[:784]
    return w1t[:, :784], b1, mult, shift, img


def rgb_div(v, vmax):
    """Diverging colors as in the site: red negative, blue positive."""
    u = np.clip(v / vmax, -1, 1)
    a = np.abs(u) ** 0.8
    base = np.array([17, 25, 35], float)
    pos, neg = np.array([88, 196, 221], float), np.array([252, 98, 85], float)
    out = base + (np.where(u[..., None] >= 0, pos, neg) - base) * a[..., None]
    return out.astype(np.uint8)


def to_image(rgb, height):
    m = ImageMobject(rgb)
    m.set_resampling_algorithm(RESAMPLING_ALGORITHMS["nearest"])
    m.height = height
    return m


def label(s, size=26, color=INK):
    return Text(s, font=MONO, font_size=size, color=color)


class OneNeuron(Scene):
    def construct(self):
        w1, b1, mult, shift, px = load()
        x = (px >> 1).astype(np.int32)
        h_all = np.clip((((x @ w1.T.astype(np.int32)) + b1).astype(np.int64) * mult + (1 << (shift - 1))) >> shift, 0, 127)
        j = int(np.argmax(h_all))                          # the neuron that fires hardest on this 7
        w = w1[j].astype(np.int32)
        prods = x * w
        csum = np.cumsum(prods)
        acc = int(csum[-1] + b1[j])
        hq = int(np.clip((acc * mult + (1 << (shift - 1))) >> shift, 0, 127))

        title = label("One neuron is a weighted sum", 40).to_edge(UP)
        self.play(Write(title), run_time=1.2)

        # The input, as pixels, then as the card's 0..127 bytes
        gray = np.repeat((x.reshape(28, 28) * 2).astype(np.uint8)[..., None], 3, axis=2)
        xin = to_image(gray, 3.2).shift(LEFT * 4.6 + DOWN * 0.3)
        xl = label("input x: 784 bytes", 22, MUTED).next_to(xin, UP)
        self.play(FadeIn(xin), FadeIn(xl))
        self.wait(0.8)

        wim = to_image(rgb_div(w.reshape(28, 28).astype(float), 90), 3.2).shift(DOWN * 0.3)
        wl = label(f"weights of neuron {j}", 22, MUTED).next_to(wim, UP)
        times = label("×", 44, MUTED).move_to((xin.get_right() + wim.get_left()) / 2)
        self.play(FadeIn(wim), FadeIn(wl), FadeIn(times))
        note = label("blue: positive   red: negative", 20, MUTED).next_to(wim, DOWN)
        self.play(FadeIn(note))
        self.wait(1.5)

        pmax = np.abs(prods).max() * 0.6
        eq = label("=", 44, MUTED).move_to(wim.get_right() + RIGHT * 0.45)
        pl = label("products x·w", 22, MUTED).move_to(RIGHT * 4.3 + UP * 1.6)
        prod_rgb = rgb_div(prods.reshape(28, 28).astype(float), pmax)
        self.play(FadeIn(eq), FadeIn(pl), FadeOut(note))

        # Accumulate: reveal products in raster order with a running sum
        k = ValueTracker(0)
        def prod_img():
            n = int(k.get_value())
            rgb = prod_rgb.copy().reshape(784, 3)
            rgb[n:] = [20, 28, 38]
            return to_image(rgb.reshape(28, 28, 3), 3.2).move_to(RIGHT * 4.3 + DOWN * 0.3)
        pim = always_redraw(prod_img)
        total = always_redraw(lambda: label(f"Σ = {int(csum[max(0, int(k.get_value()) - 1)]) if k.get_value() >= 1 else 0:,}", 30, YELLOW)
                              .move_to(DOWN * 2.85 + RIGHT * 4.3))
        count = always_redraw(lambda: label(f"{int(k.get_value())} of 784 MACs", 20, MUTED).next_to(total, DOWN, buff=0.15))
        self.add(pim, total, count)
        self.play(k.animate.set_value(784), run_time=6, rate_func=linear)
        self.wait(0.5)
        pim.clear_updaters(); total.clear_updaters(); count.clear_updaters()

        # Bias, ReLU, requantization
        steps = VGroup(
            label(f"acc  = Σ x·w + bias = {int(csum[-1]):,} + {int(b1[j]):,} = {acc:,}", 24),
            label(f"ReLU = max(0, acc) = {max(acc, 0):,}", 24, GREEN),
            label(f"to 8 bits: (acc × {mult} + 2^{shift - 1}) >> {shift} = {hq}", 24, YELLOW),
        ).arrange(DOWN, aligned_edge=LEFT, buff=0.3)
        self.play(FadeOut(Group(xin, xl, wim, wl, times, eq, pl, pim, total, count)))
        steps.move_to(ORIGIN)
        for st in steps:
            self.play(FadeIn(st, shift=UP * 0.2), run_time=0.9)
            self.wait(0.9)
        box = SurroundingRectangle(steps[2], color=YELLOW, buff=0.15)
        hw = label("A 784-tap multiply-accumulate loop: one dot product.", 22, MUTED).next_to(steps, DOWN, buff=0.7)
        hw2 = label(f"The card computes this for 128 neurons and writes h[{j}] = {hq}.", 22, MUTED).next_to(hw, DOWN, buff=0.2)
        self.play(Create(box), FadeIn(hw), FadeIn(hw2))
        self.wait(2.5)
