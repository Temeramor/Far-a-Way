shader_type spatial;
render_mode diffuse_burley, cull_back, specular_schlick_ggx;

#include "res://shaders/materials/common.gdshaderinc"
#include "res://shaders/materials/grass.gdshaderinc"
#include "res://shaders/materials/soil.gdshaderinc"
#include "res://shaders/materials/sand.gdshaderinc"
#include "res://shaders/materials/underwater.gdshaderinc"
#include "res://shaders/materials/mountain.gdshaderinc"

uniform bool debug_lod_colors = false;
uniform vec4 skirt_visibility = vec4(1.0);
uniform float lod_cell_size = 0.2;
uniform float side_fill : hint_range(0.0, 1.0) = 0.30;
uniform float side_wrap : hint_range(0.0, 1.0) = 0.50;
uniform int lod_index = 0;

void vertex() {
    world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
    view_up_direction = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
    // Pass view-space distance to light(); fragment-stage built-ins aren't directly available there.
    camera_distance = length((VIEW_MATRIX * vec4(world_position, 1.0)).xyz);
}

void fragment() {
    // Vertex colour alpha is stored as an 8-bit channel. Decode integer codes,
    // not narrow float ranges: this leaves a safe gap between skirts, side tops and tops.
    float alpha_code = floor(COLOR.a * 255.0 + 0.5);
    if (alpha_code < 238.0) {
        float edge_visible = skirt_visibility.x;
        if (alpha_code >= 209.0 && alpha_code < 219.0) {
            edge_visible = skirt_visibility.y;
        } else if (alpha_code >= 219.0 && alpha_code < 230.0) {
            edge_visible = skirt_visibility.z;
        } else if (alpha_code >= 230.0) {
            edge_visible = skirt_visibility.w;
        }
        if (edge_visible < 0.5) discard;
    }

    rock_specular_suppression = 0.0;

    // Derivatives are valid here. Estimate the 10 cm riser footprint once and smooth
    // its lighting normal before the light pass, without any MSAA 4x full-screen cost.
    float world_units_per_pixel = 0.0;
    if (lod_index < 3) {
        world_units_per_pixel = max(length(dFdx(world_position)), length(dFdy(world_position)));
        float riser_pixels = lod_cell_size / max(world_units_per_pixel, 0.001);
        float subpixel_riser_weight = 1.0 - smoothstep(0.65, 1.35, riser_pixels);
        float side_face_weight = 1.0 - smoothstep(0.15, 0.45, abs(normalize(world_normal).y));
        NORMAL = normalize(mix(normalize(NORMAL), view_up_direction,
            side_face_weight * subpixel_riser_weight * 0.85));
    }

    vec3 normal = normalize(world_normal);
    bool is_top_surface = alpha_code >= 246.0 && alpha_code <= 253.0;
    bool is_surface_side = alpha_code >= 240.0 && alpha_code < 246.0;
    float top_rock_amount = 0.0;
    if (is_top_surface) {
        top_rock_amount = clamp((alpha_code - 246.0) / 6.0, 0.0, 1.0);
    } else if (is_surface_side) {
        top_rock_amount = clamp((alpha_code - 240.0) / 5.0, 0.0, 1.0);
    }
    // Blend XZ and wall-aligned projections according to the actual surface normal.
    // The wall projection includes world Y, so steep mountain faces retain their texture scale.
    vec2 rock_world = mountain_rock_projection(world_position, normal);

    if (debug_lod_colors) {
        if (lod_index == 0) {
            ALBEDO = vec3(0.93, 0.28, 0.28);
        } else if (lod_index == 1) {
            ALBEDO = vec3(0.91, 0.63, 0.18);
        } else if (lod_index == 2) {
            ALBEDO = vec3(0.21, 0.79, 0.70);
        } else if (lod_index == 3) {
            ALBEDO = vec3(0.33, 0.49, 0.91);
        } else if (lod_index == 4) {
            ALBEDO = vec3(0.69, 0.42, 0.88);
        } else if (lod_index == 5) {
            ALBEDO = vec3(0.92, 0.34, 0.71);
        } else {
            ALBEDO = vec3(0.35, 0.74, 0.92);
        }
        ROUGHNESS = 0.96;
    } else if (lod_index >= 3) {
        // Keep a deterministic colour per voxel at every distance. Only the palette detail
        // simplifies with LOD: the cell size follows the same 20 cm-to-25.6 m voxel ladder.
        float lod_voxel_size = lod_cell_size;
        if (is_top_surface || is_surface_side) {
            if (COLOR.r > COLOR.g * 1.15 && COLOR.r > COLOR.b * 1.35) {
                ALBEDO = sand_color(world_position.xz, lod_voxel_size);
                ROUGHNESS = 0.98;
            } else if (COLOR.g > COLOR.r * 1.35) {
                ALBEDO = voxel_lod_grass_color(world_position.xz, lod_voxel_size) * 0.95;
                ROUGHNESS = 0.95;
            } else {
                vec2 algae_cell = floor(rock_world / lod_voxel_size);
                vec2 algae_world = (algae_cell + vec2(0.5)) * lod_voxel_size;
                ALBEDO = voxel_lod_rock_color(rock_world, lod_voxel_size);
                if (world_position.y < -0.2) {
                    ALBEDO = underwater_algae_voxels(ALBEDO, algae_cell, algae_world);
                }
                ROUGHNESS = 1.0;
            }
        } else if (COLOR.g > COLOR.r * 1.35) {
            ALBEDO = voxel_lod_grass_color(world_position.xz, lod_voxel_size) * 0.95;
            ROUGHNESS = 0.95;
        } else if (COLOR.r > COLOR.g * 1.15) {
            ALBEDO = voxel_lod_soil_color(world_position.xz, lod_voxel_size);
            ROUGHNESS = 0.91;
        } else {
            vec2 algae_cell = floor(rock_world / lod_voxel_size);
            vec2 algae_world = (algae_cell + vec2(0.5)) * lod_voxel_size;
            ALBEDO = voxel_lod_rock_color(rock_world, lod_voxel_size);
            if (world_position.y < -0.2) {
                ALBEDO = underwater_algae_voxels(ALBEDO, algae_cell, algae_world);
            }
            ROUGHNESS = 1.0;
        }
    } else {
        // The voxel colour is sampled on the current LOD's cell lattice, without fading
        // to a uniform distance colour. Only fine rock cracks fade when they become sub-pixel.
        float lod_voxel_size = lod_cell_size;
        float rock_crack_footprint = world_units_per_pixel / 5.5;
        float rock_crack_weight = 1.0 - smoothstep(0.55, 1.25, rock_crack_footprint);

        if (is_top_surface || is_surface_side) {
            vec2 pixel_cell = floor(rock_world / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            if (COLOR.r > COLOR.g * 1.15 && COLOR.r > COLOR.b * 1.35) {
                ALBEDO = sand_color(world_position.xz, lod_voxel_size);
                ROUGHNESS = 0.98;
            } else if (COLOR.g > COLOR.r * 1.35) {
                ALBEDO = grass_pixel(pixel_cell, pixel_world) * (lod_index >= 2 ? 0.95 : 1.0);
                ROUGHNESS = 0.95;
            } else {
                ALBEDO = distance_aware_rock_pixel(pixel_cell, pixel_world, rock_crack_weight, lod_voxel_size);
                if (world_position.y < -0.2) {
                    ALBEDO = underwater_algae_voxels(ALBEDO, pixel_cell, pixel_world);
                }
                ROUGHNESS = 0.84;
            }
        } else if (COLOR.g > COLOR.r * 1.35) {
            vec2 pixel_cell = floor(world_position.xz / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            ALBEDO = grass_pixel(pixel_cell, pixel_world) * (lod_index >= 2 ? 0.95 : 1.0);
            ROUGHNESS = 0.95;
        } else if (COLOR.r > COLOR.g * 1.15) {
            vec2 pixel_cell = floor(world_position.xz / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            float pixel_variation = hash21(pixel_cell);
            float broad_tone = value_noise(pixel_world * 0.035);
            ALBEDO = soil_palette(0.30 + pixel_variation * 0.48 + (broad_tone - 0.5) * 0.12);
            ROUGHNESS = 0.91;
        } else {
            vec2 pixel_cell = floor(rock_world / lod_voxel_size);
            vec2 pixel_world = (pixel_cell + vec2(0.5)) * lod_voxel_size;
            ALBEDO = distance_aware_rock_pixel(pixel_cell, pixel_world, rock_crack_weight, lod_voxel_size);
            if (world_position.y < -0.2) {
                ALBEDO = underwater_algae_voxels(ALBEDO, pixel_cell, pixel_world);
            }
            ROUGHNESS = 0.84;
        }
    }

    if (!debug_lod_colors) {
        rock_specular_suppression = (is_top_surface || is_surface_side)
            ? top_rock_amount
            : ((COLOR.g > COLOR.r * 1.35 || COLOR.r > COLOR.g * 1.15) ? 0.0 : 1.0);
    }
    METALLIC = 0.0;
}

// Fade shadow-map attenuation continuously with camera distance. Shadow strength applies
// only to the upper terrain faces; vertical sides get wrap lighting and a soft directional fill.
void light() {
    vec3 light_normal = normalize(NORMAL);
    float side = 1.0 - smoothstep(0.15, 0.45, abs(normalize(world_normal).y));
    float shadow_strength = mix(0.20, 0.0, smoothstep(40.0, 500.0, camera_distance));

    float attenuation = ATTENUATION;
    if (LIGHT_IS_DIRECTIONAL) {
        attenuation = mix(mix(1.0, ATTENUATION, shadow_strength), 1.0, side);
    }
    if (LIGHT_IS_AREA) {
        DIFFUSE_LIGHT += LIGHT_AREA_DIFFUSE_MULTIPLIER * attenuation * LIGHT_COLOR;
        SPECULAR_LIGHT += LIGHT_AREA_SPECULAR_MULTIPLIER * attenuation * LIGHT_COLOR * SPECULAR_AMOUNT
            * (1.0 - rock_specular_suppression);
    } else {
        float n_dot_l = dot(light_normal, LIGHT);
        float lambert = clamp(n_dot_l, 0.0, 1.0);
        float wrapped = clamp((n_dot_l + side_wrap) / (1.0 + side_wrap), 0.0, 1.0);
        float diffuse_term = mix(lambert, wrapped, side);
        float fill = LIGHT_IS_DIRECTIONAL ? side * side_fill : 0.0;
        DIFFUSE_LIGHT += (diffuse_term * attenuation + fill) * LIGHT_COLOR / PI;
        vec3 half_vector = normalize(LIGHT + VIEW);
        float roughness = clamp(ROUGHNESS, 0.04, 1.0);
        float lobe = pow(max(dot(light_normal, half_vector), 0.0), mix(128.0, 4.0, roughness));
        SPECULAR_LIGHT += lobe * attenuation * LIGHT_COLOR * SPECULAR_AMOUNT
            * (1.0 - roughness) * 0.08 * (1.0 - rock_specular_suppression);
    }
}
