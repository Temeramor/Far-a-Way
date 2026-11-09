#!/usr/bin/env python3
"""Builds standalone (Godot-free) test tools around the REAL NoiseSet::surface_height.

It extracts `struct NoiseSet` from native/src/voxen_native_builder.cpp, replaces the
Godot-dependent configure_from_job() with a plain configure, and compiles the tools with g++.

    python3 tools/terrain_harness/build.py          # builds into tools/terrain_harness/build/
    ./tools/terrain_harness/build/waterline_and_timing
    ./tools/terrain_harness/build/render_hillshade find
    ./tools/terrain_harness/build/render_hillshade X Z SIZE_M RES out.ppm
    ./tools/terrain_harness/build/relief_stats
"""
import os, re, subprocess, sys

here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "..", "native", "src")
out_dir = os.path.join(here, "build")
os.makedirs(out_dir, exist_ok=True)

text = open(os.path.join(src, "voxen_native_builder.cpp"), encoding="utf-8").read()
consts = "".join(re.findall(r"^constexpr double (?:SHORE_|ROCK_)[^\n]*\n", text, flags=re.M))
body = text[text.index("struct NoiseSet {"):text.index("Color rgb8(")]
c0, c1 = body.index("    void configure_from_job"), body.index("    double coast_distance")
plain = """    void configure_plain(double ws) {
        world_size_m = ws;
        const float fs = static_cast<float>(std::clamp(10000.0 / std::max(ws, 1.0), 0.35, 6.0));
        macro.SetFrequency(0.00028f * fs); hills.SetFrequency(0.00115f * fs);
        detail.SetFrequency(0.0048f * fs); ridges.SetFrequency(0.00082f * fs);
        micro_ridge.SetFrequency(0.0034f * fs); transition.SetFrequency(0.008f * fs);
        pg_island.generate(seed_value, world_size_m);
        rock_detail.configure(seed_value);
        micro_erosion = make_noise(static_cast<int32_t>(seed_value + 2903), 3, 0.52f); micro_erosion.SetFrequency(0.16f);
        fine_grain = make_noise(static_cast<int32_t>(seed_value + 2909), 2, 0.48f); fine_grain.SetFrequency(0.62f);
        meso_detail = make_noise(static_cast<int32_t>(seed_value + 2917), 3, 0.48f, true); meso_detail.SetFrequency(0.28f * fs);
    }
"""
body = body[:c0] + plain + body[c1:]
body = re.sub(r"    Vector3 surface_sample.*?    int32_t surface_height_voxels", "    int32_t surface_height_voxels", body, flags=re.S)
impl = f'''#include "{os.path.join(src, "pg_island_terrain.h")}"
#include "{os.path.join(src, "terrain_detail.h")}"
#include <mutex>
#include <unordered_map>
#include <limits>
#include <memory>
namespace {{
constexpr double VOXEL_SIZE = 0.2; constexpr int32_t VERTICAL_OFFSET_VOXELS = 1536;
constexpr int AIR = 0, GRASS = 1, SOIL = 2, ROCK = 3, SAND = 4;
{consts}
{body}
}}
void* make_set(long seed, double ws) {{ auto *n = new NoiseSet(seed); n->configure_plain(ws); return n; }}
double hs(void *n, double x, double z) {{ return static_cast<NoiseSet *>(n)->surface_height(x, z); }}
double hc(void *n, double x, double z) {{ return static_cast<NoiseSet *>(n)->pg_island.sample_coast(x, z); }}
double hr(void *n, double x, double z) {{ return static_cast<NoiseSet *>(n)->pg_island.shore_rocky(x, z); }}
'''
impl_path = os.path.join(out_dir, "noise_set_impl.cpp")
open(impl_path, "w", encoding="utf-8").write(impl)
for tool, files in (("waterline_and_timing", ["waterline_and_timing.cpp", impl_path]),
                    ("render_hillshade", ["render_hillshade.cpp", impl_path]),
                    ("relief_stats", ["relief_stats.cpp"])):
    files = [f if os.path.isabs(f) else os.path.join(here, f) for f in files]
    cmd = ["g++", "-O2", "-std=c++17", *files, "-o", os.path.join(out_dir, tool)]
    print(" ".join(cmd)); subprocess.check_call(cmd)
