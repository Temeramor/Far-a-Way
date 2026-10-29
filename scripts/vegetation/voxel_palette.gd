class_name VoxPalette
extends RefCounted
## Квантованная "пиксельная" палитра: берём реальный цвет и подбираем
## несколько соседних оттенков на сетке палитры (32 уровня на канал).

const LEVELS := 32


static func quantize(c: Color) -> Color:
    var l := float(LEVELS - 1)
    return Color(roundf(c.r * l) / l, roundf(c.g * l) / l, roundf(c.b * l) / l)


## Возвращает count соседних оттенков base, отсортированных от тёмного к светлому.
static func shades(base: Color, count: int, rng: RandomNumberGenerator,
        hue_spread: float = 0.02, sat_spread: float = 0.1, val_spread: float = 0.15) -> PackedColorArray:
    var res: Array[Color] = []
    var tries := 0
    while res.size() < count and tries < count * 10:
        tries += 1
        var h := fposmod(base.h + rng.randf_range(-hue_spread, hue_spread), 1.0)
        var s := clampf(base.s + rng.randf_range(-sat_spread, sat_spread), 0.0, 1.0)
        var v := clampf(base.v + rng.randf_range(-val_spread, val_spread), 0.0, 1.0)
        var c := quantize(Color.from_hsv(h, s, v))
        if not res.has(c):
            res.append(c)
    if res.is_empty():
        res.append(quantize(base))
    res.sort_custom(func(a: Color, b: Color) -> bool: return a.v < b.v)
    return PackedColorArray(res)
