# Lesson videos

[Manim](https://www.manim.community/) scenes (the animation library 3Blue1Brown's videos are made with) that tell parts of the [lessons](../../site/public/learn/) as video, from the same real data: the card's model, the MNIST test images, and the card's arithmetic.

| Scene | File | On the site |
| --- | --- | --- |
| One neuron is a weighted sum: test image #0, the neuron that fires hardest on it, 784 MACs with a running sum, bias, ReLU, requantization to the card's 8-bit value | `neuron.py`, `OneNeuron` | `learn/video/one-neuron.mp4`, linked from lesson 1.2 |

The interactive lessons are the complete set (fourteen scenes); the videos are a pilot. Their narration is the text of the matching lesson steps (`site/public/learn/scenes-*.js`).

## Render

Manim needs Cairo, Pango and ffmpeg (all present on this build machine) and Python packages in their own venv:

```sh
python3 -m venv ~/fpga/venv-manim && ~/fpga/venv-manim/bin/pip install manim
~/fpga/venv-manim/bin/python sw/mnist/train.py                    # if build/mnist/ is missing
~/fpga/venv-manim/bin/manim -qm --media_dir build/manim sw/lessons/neuron.py OneNeuron    # 720p30, about 30 s
~/fpga/venv-manim/bin/manim -qh --media_dir build/manim sw/lessons/neuron.py OneNeuron    # 1080p60
```

Output lands in `build/manim/videos/`. Formulas are set as plain text, because LaTeX is not installed; with a TeX distribution (on Arch: `texlive-basic texlive-latex texlive-latexrecommended texlive-latexextra texlive-fontsrecommended texlive-binextra texlive-mathscience`) the scenes could use Manim's `MathTex`. Text uses the JetBrainsMono Nerd Font installed on this machine; Manim falls back to another font if it is missing.
