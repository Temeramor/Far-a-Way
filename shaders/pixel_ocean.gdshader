shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, specular_schlick_ggx;

uniform sampler2D scene_depth : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D scene_color : hint_screen_texture, repeat_disable, filter_nearest;
uniform float pixel_world_size = 0.2;
uniform float wave_speed = 1.0;
uniform float wave_height = 1.0;
uniform float refraction_strength = 0.010;
uniform vec3 shallow_color : source_color = vec3(0.075, 0.34, 0.38);
uniform vec3 deep_color : source_color = vec3(0.008, 0.045, 0.085);
uniform vec3 foam_color : source_color = vec3(0.72, 0.82, 0.78);

varying vec3 water_world_position;
varying vec3 water_world_normal;

const vec4 WAVES[4] = vec4[4](
    vec4(1.00, 0.12, 0.92, 250.0),
    vec4(0.58, 0.82, 0.66, 150.0),
    vec4(-0.36, 0.93, 0.42, 88.0),
    vec4(0.91, -0.48, 0.26, 82.0)
);

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float value_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

vec3 wave_displacement(vec2 p, float time, out vec3 n) {
    vec3 offset = vec3(0.0);
    vec3 tangent = vec3(1.0, 0.0, 0.0);
    vec3 binormal = vec3(0.0, 0.0, 1.0);
    for (int i = 0; i < 4; i++) {
        vec2 direction = normalize(WAVES[i].xy);
        float wavelength = WAVES[i].w;
        float k = TAU / wavelength;
        float amplitude = wave_height * WAVES[i].z * wavelength / 150.0;
        float speed = sqrt(9.81 / k);
        float phase = k * (dot(direction, p) - speed * time * wave_speed);
        float sn = sin(phase);
        float cs = cos(phase);
        float qa = min(0.34 * k * amplitude, 0.95);
        offset.xz += 0.34 * amplitude * direction * cs;
        offset.y += amplitude * sn;
        tangent += vec3(-qa * direction.x * direction.x * sn, direction.x * k * amplitude * cs, -qa * direction.x * direction.y * sn);
        binormal += vec3(-qa * direction.x * direction.y * sn, direction.y * k * amplitude * cs, -qa * direction.y * direction.y * sn);
    }
    n = normalize(cross(binormal, tangent));
    return offset;
}

void vertex() {
    vec3 base_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    vec3 wave_normal;
    vec3 displacement = wave_displacement(base_world.xz, TIME, wave_normal);
    VERTEX += displacement;
    NORMAL = wave_normal;
    water_world_position = base_world + displacement;
    water_world_normal = normalize((MODEL_MATRIX * vec4(wave_normal, 0.0)).xyz);
}

void fragment() {
    // All water detail is evaluated on a 20 cm world-space lattice. The geometry
    // remains smooth enough for stable silhouettes while color, ripples and glints
    // resolve as discrete pixels instead of a blurred normal-map effect.
    vec2 pixel_world = floor(water_world_position.xz / pixel_world_size) * pixel_world_size;
    float ripple_a = value_noise(pixel_world * 0.025 + vec2(TIME * 0.06, -TIME * 0.045));
    float ripple_b = value_noise(pixel_world * 0.11 + vec2(-TIME * 0.10, TIME * 0.08) + 17.4);
    vec3 world_n = normalize(water_world_normal + vec3((ripple_a - 0.5) * 0.18, 0.0, (ripple_b - 0.5) * 0.18));
    vec3 view_n = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);

    float depth_value = texture(scene_depth, SCREEN_UV).r;
    vec4 scene_h = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_value, 1.0);
    vec3 scene_view = scene_h.xyz / max(scene_h.w, 0.00001);
    float water_view_z = (VIEW_MATRIX * vec4(water_world_position, 1.0)).z;
    float thickness = max(water_view_z - scene_view.z, 0.0);
    vec2 snapped_uv = floor(SCREEN_UV / ((1.0 / VIEWPORT_SIZE) * 2.0)) * (SCREEN_PIXEL_SIZE * 2.0);
    vec2 refracted_uv = clamp(snapped_uv + view_n.xy * refraction_strength, vec2(0.001), vec2(0.999));
    vec3 transmitted = texture(scene_color, refracted_uv).rgb;
    float depth_mix = 1.0 - exp(-thickness * 0.045);
    vec3 water_color = mix(transmitted * vec3(0.72, 0.88, 0.90), mix(shallow_color, deep_color, depth_mix), 0.62);

    float crest = smoothstep(0.76, 0.94, ripple_a * 0.58 + ripple_b * 0.42);
    float shore = 1.0 - smoothstep(0.25, 3.2, thickness);
    float foam = max(crest * 0.20, shore * smoothstep(0.44, 0.82, ripple_b));
    water_color = mix(water_color, foam_color, foam);

    float fresnel = pow(1.0 - clamp(dot(view_n, VIEW), 0.0, 1.0), 5.0);
    // Quantized reflected-light glints sit on top of Godot's environment specular,
    // which carries the current sky, sun/moon and cloud lighting.
    float glint = step(0.965, hash12(floor(pixel_world * 0.5) + floor(TIME * 2.0)));
    water_color += vec3(0.30, 0.38, 0.42) * glint * fresnel * (1.0 - foam) * 0.35;
    water_color = floor(clamp(water_color, vec3(0.0), vec3(1.0)) * 31.0 + 0.5) / 31.0;

    ALBEDO = water_color;
    ROUGHNESS = mix(0.18, 0.76, foam);
    SPECULAR = 0.82;
    METALLIC = 0.12;
    ALPHA = clamp(0.84 + fresnel * 0.12 + foam * 0.04, 0.0, 0.98);
    NORMAL = view_n;
}
