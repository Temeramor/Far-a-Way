#pragma once

// World-anchored rock detail layered on top of the macro heightfield (PG-Island raster).
//
// The macro raster is ~3.9 m per sample, smoothed by erosion + thermal relaxation, and
// reconstructed with bicubic interpolation, so steep faces come out as smooth, even ramps.
// This class adds what that pipeline cannot represent, only on steep rock:
//   1. rugosity     - ridged ribs and Voronoi "block" cracks (1-25 m scale),
//   2. strata       - horizontal ledges (benches) with a recessed groove under each lip,
//                     three scales; larger strata are active in fewer places,
//   3. niches       - recesses elongated ALONG the contour (horizontal hollows) in four
//                     size classes; the deeper the class, the lower its probability.
//
// Everything is a pure function of (x, z, macro height, macro gradient) and the seed, so
// chunk borders and LODs stay exactly consistent. The mesher builds one height per
// (x, z) column, so these are shelves, grooves and scooped hollows - not true overhangs.
// Real roofs/caves need a mesher that supports several solid spans per column.

#include "../thirdparty/FastNoiseLite.h"
#include "pg_island_terrain.h"

#include <algorithm>
#include <cmath>
#include <cstdint>

namespace voxen {

class TerrainDetail {
public:
    // --- Where rock detail appears (macro slope = rise/run) -----------------------------
    static constexpr double ROCK_SLOPE_START = 0.40;  // ~22 degrees: first traces
    static constexpr double ROCK_SLOPE_FULL = 1.05;   // ~46 degrees: full strength

    // --- Rugosity ------------------------------------------------------------------------
    static constexpr double RIB_AMPLITUDE_M = 1.7;
    static constexpr double BLOCK_AMPLITUDE_M = 1.1;

    // --- Strata (horizontal ledges). Fractions of the stratum thickness are used for the
    // bench/groove shape; probability falls with scale through the activation threshold. ---
    struct StrataLevel {
        double thickness_m;   // vertical period of the layering
        double patch_freq;    // horizontal frequency of the "is this layer expressed here" mask
        double threshold;     // higher = rarer (noise is roughly in [-0.8, 0.8])
        double strength;      // 0..1 how far the face is pulled toward a stepped profile
        double groove;        // groove depth as a fraction of thickness
    };
    static constexpr StrataLevel STRATA[3] = {
        {1.7, 0.060, -0.05, 0.40, 0.06},    // common, small shelves
        {5.5, 0.022, 0.32, 0.55, 0.09},    // medium ledges
        {17.0, 0.009, 0.60, 0.50, 0.08},   // rare, large benches
    };

    // --- Niches: horizontal recesses. Probability and depth trade off by class. --------
    struct NicheLevel {
        double cell_m;        // jittered grid cell size = class size
        double probability;   // chance that a cell holds a niche
        double depth_m;       // maximum vertical cut
        double min_height_m;  // fade-in range: no big hollows on low coastal rocks
        double full_height_m;
    };
    static constexpr NicheLevel NICHES[4] = {
        {3.5, 0.38, 0.30, 0.0, 0.0},       // shallow dents: most common
        {11.0, 0.20, 1.30, 3.0, 10.0},     // hollows
        {34.0, 0.075, 4.2, 14.0, 40.0},    // overhang-like alcoves
        {100.0, 0.020, 11.0, 45.0, 110.0}, // cave-sized hollows: very rare
    };

    int64_t seed = 0;
    fastnoiselite::FastNoiseLite ribs, cells, strata_patch, strata_warp;

    void configure(int64_t p_seed) {
        seed = p_seed;
        ribs = make(static_cast<int32_t>(seed + 3101), 3, 0.5f, 0.045f);
        ribs.SetFractalType(fastnoiselite::FastNoiseLite::FractalType_Ridged);
        cells.SetSeed(static_cast<int32_t>(seed + 3119));
        cells.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_Cellular);
        cells.SetCellularDistanceFunction(fastnoiselite::FastNoiseLite::CellularDistanceFunction_Euclidean);
        cells.SetCellularReturnType(fastnoiselite::FastNoiseLite::CellularReturnType_Distance2Sub);
        cells.SetCellularJitter(1.0f);
        cells.SetFrequency(0.11f);
        strata_patch = make(static_cast<int32_t>(seed + 3137), 1, 0.5f, 1.0f);
        strata_warp = make(static_cast<int32_t>(seed + 3163), 2, 0.5f, 1.0f);
    }

    static double smooth(double a, double b, double v) {
        const double t = std::clamp((v - a) / (b - a), 0.0, 1.0);
        return t * t * (3.0 - 2.0 * t);
    }

    // Weight 0..1 for "this face is steep rock". Callers can skip the whole layer at 0.
    static double rock_weight(double slope) { return smooth(ROCK_SLOPE_START, ROCK_SLOPE_FULL, slope); }

    // Height delta (metres) to add at (x, z). `h` is the macro height, (gx, gz) the macro
    // gradient in metres of height per metre of distance.
    double relief(double x, double z, double h, double gx, double gz) const {
        const double slope = std::hypot(gx, gz);
        const double rock = rock_weight(slope);
        if (rock <= 1e-3) return 0.0;

        // Low coastal rocks get calmer detail than mountain faces.
        const double scale = 0.45 + 0.55 * smooth(5.0, 60.0, h);
        double delta = rugosity(x, z) * rock * scale;
        delta += strata_ledges(x, z, h) * rock * scale;
        delta -= niches(x, z, h, gx, gz, slope) * rock;
        return delta;
    }

private:
    static fastnoiselite::FastNoiseLite make(int32_t s, int octaves, float gain, float frequency) {
        fastnoiselite::FastNoiseLite n;
        n.SetSeed(s);
        n.SetNoiseType(fastnoiselite::FastNoiseLite::NoiseType_OpenSimplex2);
        n.SetFractalType(octaves > 1 ? fastnoiselite::FastNoiseLite::FractalType_FBm
                                     : fastnoiselite::FastNoiseLite::FractalType_None);
        n.SetFractalOctaves(octaves);
        n.SetFractalLacunarity(2.05f);
        n.SetFractalGain(gain);
        n.SetFrequency(frequency);
        return n;
    }
    static double sample(const fastnoiselite::FastNoiseLite &n, double x, double z) {
        return static_cast<double>(n.GetNoise(static_cast<float>(x), static_cast<float>(z)));
    }

    double rugosity(double x, double z) const {
        // Ridged noise is skewed positive (crease lines are +1); re-centre so it adds no net lift.
        const double rib = sample(ribs, x, z) - RIB_MEAN;
        // Distance2Sub + 1 is ~0 on Voronoi borders: cracks between blocks, bulging block centres.
        const double edge = sample(cells, x, z) + 1.0;
        const double block = smooth(0.0, 0.55, edge) - 0.45;
        return rib * RIB_AMPLITUDE_M + block * BLOCK_AMPLITUDE_M;
    }

    double strata_ledges(double x, double z, double h) const {
        double total = 0.0;
        for (int k = 0; k < 3; ++k) {
            const StrataLevel &lv = STRATA[k];
            // Warp the layering so strata undulate instead of forming perfect contour rings.
            const double offset =
                sample(strata_warp, x * 0.012 + k * 41.0, z * 0.012 - k * 23.0) * lv.thickness_m * 0.9 +
                sample(strata_warp, x * 0.05 - k * 13.0, z * 0.05 + k * 57.0) * lv.thickness_m * 0.35;
            const double t = (h + offset) / lv.thickness_m;
            const double layer = std::floor(t);
            const double f = t - layer;
            const int64_t id = static_cast<int64_t>(layer);
            const double wrapped = static_cast<double>(((id % 97) + 97) % 97);
            // A given layer is expressed only in patches; rarer thresholds = fewer places.
            const double active = smooth(lv.threshold, lv.threshold + 0.18,
                sample(strata_patch, x * lv.patch_freq + wrapped * 31.7,
                    z * lv.patch_freq - wrapped * 17.9));
            if (active <= 0.0) continue;
            const double step = smooth(0.42, 0.90, f);   // flat bench, then a riser
            const double groove = smooth(0.72, 0.90, f) * (1.0 - smooth(0.90, 0.99, f));
            total += active * lv.thickness_m * (lv.strength * (step - f) - lv.groove * groove);
        }
        return total;
    }

    // Returns the (positive) depth of material removed at this point.
    double niches(double x, double z, double h, double gx, double gz, double slope) const {
        const double inv = 1.0 / std::max(slope, 1e-4);
        const double along_x = -gz * inv, along_z = gx * inv;  // contour tangent: horizontal
        const double up_x = gx * inv, up_z = gz * inv;         // uphill
        double cut = 0.0;
        for (int k = 0; k < 4; ++k) {
            const NicheLevel &lv = NICHES[k];
            const double gate = lv.full_height_m <= lv.min_height_m
                ? 1.0 : smooth(lv.min_height_m, lv.full_height_m, h);
            if (gate <= 0.0) continue;
            const int cx0 = static_cast<int>(std::floor(x / lv.cell_m));
            const int cz0 = static_cast<int>(std::floor(z / lv.cell_m));
            for (int oz = -1; oz <= 1; ++oz) {
                for (int ox = -1; ox <= 1; ++ox) {
                    const int cx = cx0 + ox, cz = cz0 + oz;
                    if (PgIslandTerrain::hash01(cx, cz, seed, 11 + k, 0) >= lv.probability) continue;
                    const double px = (cx + 0.15 + 0.70 * PgIslandTerrain::hash01(cx, cz, seed, 11 + k, 1)) * lv.cell_m;
                    const double pz = (cz + 0.15 + 0.70 * PgIslandTerrain::hash01(cx, cz, seed, 11 + k, 2)) * lv.cell_m;
                    const double half_len = lv.cell_m * (0.32 + 0.40 * PgIslandTerrain::hash01(cx, cz, seed, 11 + k, 3));
                    const double half_wid = lv.cell_m * (0.12 + 0.14 * PgIslandTerrain::hash01(cx, cz, seed, 11 + k, 4));
                    const double depth = lv.depth_m * (0.55 + 0.45 * PgIslandTerrain::hash01(cx, cz, seed, 11 + k, 5));
                    const double dx = x - px, dz = z - pz;
                    const double u = (dx * along_x + dz * along_z) / half_len;
                    const double v = (dx * up_x + dz * up_z) / half_wid;
                    const double r2 = u * u + v * v;
                    if (r2 >= 1.0) continue;
                    const double bump = 1.0 - r2;
                    cut = std::max(cut, depth * bump * bump * gate);  // overlapping niches merge, not stack
                }
            }
        }
        return cut;
    }

    // Mean of the ridged noise output, measured over a 4 km x 4 km area.
    static constexpr double RIB_MEAN = 0.06;
};

} // namespace voxen
