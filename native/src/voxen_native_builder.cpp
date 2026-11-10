#include "voxen_native_builder.h"
#include "voxen_terrain_sampler.h"
#include "voxen_heightfield_mesher.h"
#include "voxen_heightfield_collision_builder.h"
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/time.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <atomic>
#include <cstdint>
#include <memory>
using namespace godot;
using namespace godot::voxen_detail;
void VoxEnNativeBuilder::_bind_methods() {
    ClassDB::bind_method(
        D_METHOD("build_mesh_data", "job_data"),
        &VoxEnNativeBuilder::build_mesh_data);
    ClassDB::bind_method(D_METHOD("cancel"), &VoxEnNativeBuilder::cancel);
    ClassDB::bind_method(D_METHOD("is_cancelled"), &VoxEnNativeBuilder::is_cancelled);
    ClassDB::bind_method(D_METHOD("configure_terrain_sampler", "job_data"), &VoxEnNativeBuilder::configure_terrain_sampler);
    ClassDB::bind_method(D_METHOD("share_terrain_sampler", "source"), &VoxEnNativeBuilder::share_terrain_sampler);
    ClassDB::bind_method(D_METHOD("get_surface_height", "x", "z"), &VoxEnNativeBuilder::get_surface_height);
    ClassDB::bind_method(D_METHOD("get_surface_rock_weight", "slope", "x", "z"), &VoxEnNativeBuilder::get_surface_rock_weight);
    ClassDB::bind_method(D_METHOD("get_surface_material", "height_m", "slope", "x", "z"), &VoxEnNativeBuilder::get_surface_material);
    ClassDB::bind_method(D_METHOD("get_surface_sample", "x", "z", "step_m"), &VoxEnNativeBuilder::get_surface_sample);
    ClassDB::bind_method(D_METHOD("sample_height_grid", "origin_x", "origin_z", "columns", "rows", "step_m"), &VoxEnNativeBuilder::sample_height_grid);
    ClassDB::bind_method(D_METHOD("set_result", "value"), &VoxEnNativeBuilder::set_result);
    ClassDB::bind_method(D_METHOD("get_result"), &VoxEnNativeBuilder::get_result);
    ADD_PROPERTY(PropertyInfo(Variant::DICTIONARY, "result"), "set_result", "get_result");
}

Dictionary VoxEnNativeBuilder::build_mesh_data(const Dictionary &job_data) {
    const int64_t started_usec = Time::get_singleton()->get_ticks_usec();
    const int64_t seed = static_cast<int64_t>(job_data.get("seed", 240518));
    std::shared_ptr<NoiseSet> shared_sampler;
    if (terrain_sampler_data) {
        shared_sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    }
    MeshBuild build(seed, &cancel_requested, shared_sampler);
    result = build.run(job_data, started_usec);
    if (cancel_requested.load(std::memory_order_relaxed)) {
        result = Dictionary();
    }
    return result;
}

void VoxEnNativeBuilder::cancel() {
    cancel_requested.store(true, std::memory_order_relaxed);
}

bool VoxEnNativeBuilder::is_cancelled() const {
    return cancel_requested.load(std::memory_order_relaxed);
}

void VoxEnNativeBuilder::share_terrain_sampler(Object *source) {
    VoxEnNativeBuilder *source_builder = Object::cast_to<VoxEnNativeBuilder>(source);
    if (source_builder != nullptr) {
        terrain_sampler_data = source_builder->terrain_sampler_data;
    }
}

void VoxEnNativeBuilder::configure_terrain_sampler(const Dictionary &job_data) {
    const int64_t seed = static_cast<int64_t>(job_data.get("seed", 1337));
    const double world_size_m = static_cast<double>(job_data.get("terrain_world_size_m", 2000.0));
    auto sampler = std::make_shared<NoiseSet>(seed);
    sampler->configure_from_job(job_data, world_size_m);
    terrain_sampler_data = std::static_pointer_cast<void>(sampler);
}

double VoxEnNativeBuilder::get_surface_height(double x, double z) const {
    if (!terrain_sampler_data) return VOXEL_SIZE;
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->surface_height_cached(x, z);
}

double VoxEnNativeBuilder::get_surface_rock_weight(double slope, double x, double z) const {
    if (!terrain_sampler_data) return 0.0;
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->surface_rock_weight(slope, x, z);
}

int32_t VoxEnNativeBuilder::get_surface_material(double height_m, double slope, double x, double z) const {
    if (!terrain_sampler_data) return GRASS;
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->surface_material(height_m, slope, x, z);
}

Vector3 VoxEnNativeBuilder::get_surface_sample(double x, double z, double step_m) const {
    if (!terrain_sampler_data) return Vector3(VOXEL_SIZE, 0.0, 0.0);
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->surface_sample(x, z, step_m);
}

PackedFloat32Array VoxEnNativeBuilder::sample_height_grid(double origin_x, double origin_z,
        int32_t columns, int32_t rows, double step_m) const {
    if (!terrain_sampler_data) return PackedFloat32Array();
    const auto sampler = std::static_pointer_cast<NoiseSet>(terrain_sampler_data);
    return sampler->sample_height_grid(origin_x, origin_z, columns, rows, step_m);
}

void VoxEnNativeBuilder::set_result(const Dictionary &value) {
    result = value;
}

Dictionary VoxEnNativeBuilder::get_result() const {
    return result;
}
