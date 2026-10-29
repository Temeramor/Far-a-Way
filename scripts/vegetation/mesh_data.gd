class_name MeshData
extends RefCounted
## Накопитель геометрии (вершины/нормали/цвета/индексы) для одного чанка.

var verts := PackedVector3Array()
var normals := PackedVector3Array()
var colors := PackedColorArray()
var uv2s := PackedVector2Array()
var indices := PackedInt32Array()


## Углы a,b,c,d заданы против часовой стрелки при взгляде снаружи.
## Godot считает лицевой гранью обход по часовой, поэтому индексы идут (0,2,1),(0,3,2).
func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, col: Color, wind_weights: Vector4 = Vector4.ZERO) -> void:
    var i := verts.size()
    verts.push_back(a)
    verts.push_back(b)
    verts.push_back(c)
    verts.push_back(d)
    normals.push_back(n)
    normals.push_back(n)
    normals.push_back(n)
    normals.push_back(n)
    colors.push_back(col)
    colors.push_back(col)
    colors.push_back(col)
    colors.push_back(col)
    uv2s.push_back(Vector2(wind_weights.x, 0.0))
    uv2s.push_back(Vector2(wind_weights.y, 0.0))
    uv2s.push_back(Vector2(wind_weights.z, 0.0))
    uv2s.push_back(Vector2(wind_weights.w, 0.0))
    indices.push_back(i)
    indices.push_back(i + 2)
    indices.push_back(i + 1)
    indices.push_back(i)
    indices.push_back(i + 3)
    indices.push_back(i + 2)


func build() -> ArrayMesh:
    if verts.is_empty():
        return null
    var arrays := []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = verts
    arrays[Mesh.ARRAY_NORMAL] = normals
    arrays[Mesh.ARRAY_COLOR] = colors
    arrays[Mesh.ARRAY_TEX_UV2] = uv2s
    arrays[Mesh.ARRAY_INDEX] = indices
    var m := ArrayMesh.new()
    m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    return m
