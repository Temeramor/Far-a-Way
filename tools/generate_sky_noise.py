#!/usr/bin/env python3
"""Generate a seamless, broad-form cloud noise map used in Neverland's clear weather.

Cloudy and overcast weather use a separate bundled cloud-noise image.
This map uses fewer, wider noise islands so a clear sky produces larger open gaps.
Requires Python 3, NumPy and Pillow: python tools/generate_sky_noise.py
"""
from pathlib import Path
import numpy as np
from PIL import Image

PROJECT_ROOT = Path(__file__).resolve().parents[1]
OUTPUT = PROJECT_ROOT / "assets" / "sky" / "cloud_noise_sparse.png"
SIZE = 512
SEED = 2046


def tileable_value_noise(size: int, cells: int, rng: np.random.Generator) -> np.ndarray:
    """Bilinearly interpolate a periodic random grid with a smooth fade curve."""
    grid = rng.random((cells, cells), dtype=np.float32)
    coords = np.arange(size, dtype=np.float32) * (cells / size)
    base = np.floor(coords).astype(np.int32)
    frac = coords - base
    # Quintic fade removes visible slope changes at cell boundaries.
    frac = frac * frac * frac * (frac * (frac * 6.0 - 15.0) + 10.0)
    nxt = (base + 1) % cells
    base %= cells

    x0 = base[None, :]
    x1 = nxt[None, :]
    y0 = base[:, None]
    y1 = nxt[:, None]
    fx = frac[None, :]
    fy = frac[:, None]

    a = grid[y0, x0] * (1.0 - fx) + grid[y0, x1] * fx
    b = grid[y1, x0] * (1.0 - fx) + grid[y1, x1] * fx
    return a * (1.0 - fy) + b * fy


def main() -> None:
    rng = np.random.default_rng(SEED)
    # Broad base shapes dominate; smaller octaves only roughen the cloud edges.
    octave_specs = [(4, 0.46), (8, 0.25), (16, 0.14), (32, 0.09), (64, 0.06)]
    noise = np.zeros((SIZE, SIZE), dtype=np.float32)
    total_weight = 0.0
    for cells, weight in octave_specs:
        noise += tileable_value_noise(SIZE, cells, rng) * weight
        total_weight += weight
    noise /= total_weight

    # Remap the lower half to darker gaps while preserving soft cloud banks.
    centered = np.clip((noise - 0.5) * 1.48 + 0.5, 0.0, 1.0)
    centered = centered ** 1.18
    pixels = np.asarray(np.round(centered * 255.0), dtype=np.uint8)

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(pixels, mode="L").save(OUTPUT, optimize=True)
    print(f"Generated {OUTPUT} ({SIZE}x{SIZE}, seamless grayscale cloud noise)")


if __name__ == "__main__":
    main()
