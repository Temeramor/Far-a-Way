class_name VoxGrid
extends RefCounted
## Плотная воксельная сетка. Значение ячейки = индекс цвета в палитре (0 = пусто).
## Палитра состоит из "рамп" (наборов соседних оттенков). При генерации меша
## цвет каждой грани слегка смещается внутри своей рампы -> пиксельный шум текстуры.

const DIRS := [Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
        Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const NORMALS := [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
        Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]
const CORNERS := [
    [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
    [Vector3(0, 0, 0), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0)],
    [Vector3(0, 1, 0), Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)],
    [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)],
    [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1)],
    [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)],
]

var w: int
var h: int
var d: int
var wd: int
var ox: int
var oz: int
var cells := PackedByteArray()
var filled := PackedInt32Array()
var palette := PackedColorArray([Color.BLACK])
var ramp_lo := PackedInt32Array([0])
var ramp_hi := PackedInt32Array([0])
var meta := {}


func _init(w_: int, h_: int, d_: int) -> void:
    w = w_
    h = h_
    d = d_
    wd = w * d
    ox = w >> 1
    oz = d >> 1
    cells.resize(w * h * d)


## Добавляет набор оттенков, возвращает индекс первого.
func add_ramp(cols: PackedColorArray) -> int:
    var start := palette.size()
    if start + cols.size() > 255:
        return maxi(1, start - cols.size())
    for c in cols:
        palette.push_back(c)
        ramp_lo.push_back(start)
        ramp_hi.push_back(start + cols.size() - 1)
    return start


## Координаты относительно центра (ox, oz).
func put(x: int, y: int, z: int, i: int) -> void:
    x += ox
    z += oz
    if x < 0 or x >= w or y < 0 or y >= h or z < 0 or z >= d:
        return
    var idx := x + z * w + y * wd
    if cells[idx] == 0:
        filled.push_back(idx)
    cells[idx] = i


func put_empty(x: int, y: int, z: int, i: int) -> void:
    x += ox
    z += oz
    if x < 0 or x >= w or y < 0 or y >= h or z < 0 or z >= d:
        return
    var idx := x + z * w + y * wd
    if cells[idx] == 0:
        filled.push_back(idx)
        cells[idx] = i


func put_raw(x: int, y: int, z: int, i: int) -> void:
    var idx := x + z * w + y * wd
    if cells[idx] == 0:
        filled.push_back(idx)
    cells[idx] = i


## Грубая копия (вокселы 2x2x2 -> 1) для LOD дальних чанков.
func downsampled() -> VoxGrid:
    var g := VoxGrid.new((w + 1) >> 1, (h + 1) >> 1, (d + 1) >> 1)
    g.ox = ox >> 1
    g.oz = oz >> 1
    g.palette = palette
    g.ramp_lo = ramp_lo
    g.ramp_hi = ramp_hi
    for idx in filled:
        var y := idx / wd
        var rem := idx - y * wd
        var z := rem / w
        var x := rem - z * w
        g.put_raw(x >> 1, y >> 1, z >> 1, cells[idx])
    return g


## Генерирует грани только на границе с пустотой.
func emit(md: MeshData, offset: Vector3, vs: float, seed_val: int) -> void:
    var np := palette.size()
    for idx in filled:
        var v: int = cells[idx]
        if v >= np:
            continue
        var y := idx / wd
        var rem := idx - y * wd
        var z := rem / w
        var x := rem - z * w
        var base := offset + Vector3(x - ox, y, z - oz) * vs
        var lo := ramp_lo[v]
        var hi := ramp_hi[v]
        for f in 6:
            if f == 3 and y == 0:
                continue
            var dv: Vector3i = DIRS[f]
            var nx := x + dv.x
            var ny := y + dv.y
            var nz := z + dv.z
            if nx >= 0 and nx < w and ny >= 0 and ny < h and nz >= 0 and nz < d:
                if cells[nx + nz * w + ny * wd] != 0:
                    continue
            var hs := (x * 73856093) ^ (y * 19349663) ^ (z * 83492791) ^ (f * 2654435761) ^ seed_val
            hs = (hs ^ (hs >> 15)) & 0x7fffffff
            var r := hs % 4
            var off := 0
            if r == 0:
                off = -1
            elif r == 3:
                off = 1
            var col := palette[clampi(v + off, lo, hi)]
            var cs: Array = CORNERS[f]
            var wind_weights := Vector4(
                clampf((float(y) + cs[0].y) * vs / 0.75, 0.0, 1.0),
                clampf((float(y) + cs[1].y) * vs / 0.75, 0.0, 1.0),
                clampf((float(y) + cs[2].y) * vs / 0.75, 0.0, 1.0),
                clampf((float(y) + cs[3].y) * vs / 0.75, 0.0, 1.0)
            )
            md.quad(base + cs[0] * vs, base + cs[1] * vs, base + cs[2] * vs, base + cs[3] * vs, NORMALS[f], col, wind_weights)
