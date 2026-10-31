#pragma once

#include <atomic>
#include <cstdint>
#include <memory>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class VoxEnNativeBuilder : public RefCounted {
    GDCLASS(VoxEnNativeBuilder, RefCounted)

    Dictionary result;
    std::atomic<bool> cancel_requested{false};
    std::shared_ptr<void> terrain_sampler_data;

protected:
    static void _bind_methods();

public:
    Dictionary build_mesh_data(const Dictionary &job_data);
    void cancel();
    bool is_cancelled() const;
    void configure_terrain_sampler(const Dictionary &job_data);
    double get_surface_height(double x, double z) const;
    Vector3 get_surface_sample(double x, double z, double step_m) const;
    PackedFloat32Array sample_height_grid(double origin_x, double origin_z, int32_t columns, int32_t rows, double step_m) const;
    double get_surface_rock_weight(double slope, double x, double z) const;
    void set_result(const Dictionary &value);
    Dictionary get_result() const;
};

} // namespace godot
