#pragma once
#include "voxen_heightfield_mesher.h"
namespace godot { namespace voxen_detail {
inline Dictionary HeightfieldCollisionBuilder::build(const MeshBuild &build) {
    constexpr int32_t collision_step_voxels = 2;
    const int32_t collision_width = build.size_voxels_x / collision_step_voxels + 1;
    const int32_t collision_depth = build.size_voxels_z / collision_step_voxels + 1;
    PackedFloat32Array collision_heights;
    collision_heights.resize(static_cast<int64_t>(collision_width) * collision_depth);
    for (int32_t cz = 0; cz < collision_depth; ++cz) {
        if (build.is_cancelled()) return Dictionary();
        const double global_z = static_cast<double>(build.start_voxel_z + cz * collision_step_voxels);
        for (int32_t cx = 0; cx < collision_width; ++cx) {
            const double global_x = static_cast<double>(build.start_voxel_x + cx * collision_step_voxels);
            const int32_t h = build.cached_height_voxels(global_x, global_z);
            collision_heights.set(static_cast<int64_t>(cz) * collision_width + cx,
                static_cast<float>(h) * static_cast<float>(VOXEL_SIZE));
        }
    }
    Dictionary result;
    result["width"] = collision_width; result["depth"] = collision_depth;
    result["heights"] = collision_heights;
    result["step_m"] = static_cast<double>(collision_step_voxels) * VOXEL_SIZE;
    return result;
}
} }
