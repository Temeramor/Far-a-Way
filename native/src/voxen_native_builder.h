#pragma once

#include <atomic>

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class VoxEnNativeBuilder : public RefCounted {
    GDCLASS(VoxEnNativeBuilder, RefCounted)

    Dictionary result;
    std::atomic<bool> cancel_requested{false};

protected:
    static void _bind_methods();

public:
    Dictionary build_mesh_data(const Dictionary &job_data);
    void cancel();
    bool is_cancelled() const;
    void set_result(const Dictionary &value);
    Dictionary get_result() const;
};

} // namespace godot
