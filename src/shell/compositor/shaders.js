// shaders.js — the compositor's single WGSL module (vanilla, no build step).
//
// Focused port of ui-endlesscanvas's Compositor/shaders/* (CoreDefinitions + MathSDF + Backgrounds +
// MainFragment), concatenated into one source string. The renderer is a single fullscreen pass that loops
// every element packed into the `ui_data` texture_1d (4 texels each) and paints it with SDF rounded-boxes,
// shadows, and per-type chrome. Zero JS in the render pass.
//
// CAMERA: config._pad1/_pad2 = camera (camX, camY) in world units. The background samples world-space so it
// pans 1:1 with the camera (map-lock), and element quads of type 2.0 subtract the same camera offset — so
// "scroll wherever you want" across the infinite canvas falls out of the shader for free.
//
// Element texel layout (per element, 4× rgba32f texels):
//   t0 = (x, y, w, h)         world rect (0..1 units, origin top-left)
//   t1 = (r, g, b, a)         base color
//   t2 = (z, rotation, elementType, active)
//   t3 = (colorId, texBlend, _, _)

const CoreDefinitions = `
struct Config {
    resolution: vec2<f32>,
    time: f32,
    pad: f32,
    theme_color: vec4<f32>,
    dpi_scale: f32,
    _pad1: f32,   // camera.x (world units)
    _pad2: f32,   // camera.y (world units)
    _pad3: f32,
}

@group(0) @binding(0) var ui_data: texture_1d<f32>;
@group(0) @binding(1) var<uniform> config: Config;
@group(0) @binding(2) var mySampler: sampler;
@group(0) @binding(3) var myTexture: texture_2d<f32>;
@group(0) @binding(4) var chromeAtlas: texture_2d<f32>;
@group(0) @binding(5) var emojiAtlas: texture_2d<f32>;
@group(0) @binding(6) var fontAtlas: texture_2d<f32>;
@group(0) @binding(7) var presenterSampler: sampler;
@group(0) @binding(8) var presenterTexture: texture_2d<f32>;

struct VertexOutput {
    @builtin(position) Position: vec4<f32>,
    @location(0) uv: vec2<f32>,
}

@vertex
fn vs_main(@builtin(vertex_index) VertexIndex: u32) -> VertexOutput {
    var pos = array<vec2<f32>, 6>(
        vec2<f32>(-1.0, -1.0), vec2<f32>( 1.0, -1.0), vec2<f32>(-1.0,  1.0),
        vec2<f32>(-1.0,  1.0), vec2<f32>( 1.0, -1.0), vec2<f32>( 1.0,  1.0)
    );
    var out: VertexOutput;
    out.Position = vec4<f32>(pos[VertexIndex], 0.0, 1.0);
    out.uv = pos[VertexIndex] * 0.5 + 0.5;
    out.uv = vec2<f32>(out.uv.x, 1.0 - out.uv.y);
    return out;
}

// saturate isn't a WGSL builtin (it's GLSL/HLSL) — define it.
fn saturate(x: f32) -> f32 { return clamp(x, 0.0, 1.0); }
`;

const MathSDF = `
fn sdRoundedBox(p: vec2<f32>, b: vec2<f32>, r: f32, aspect: f32) -> f32 {
    var pAspect = p;
    var bAspect = b;
    pAspect.x *= aspect;
    bAspect.x *= aspect;
    let d = abs(pAspect) - bAspect + vec2<f32>(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, vec2<f32>(0.0))) - r;
}

fn rotate2d(uv: vec2<f32>, angle: f32, aspect: f32) -> vec2<f32> {
    var p = uv;
    p.x *= aspect;
    let s = sin(angle);
    let c = cos(angle);
    let rot = vec2<f32>(p.x * c - p.y * s, p.x * s + p.y * c);
    var rotAspect = rot;
    rotAspect.x /= aspect;
    return rotAspect;
}
`;

// Background = world-space sampled, so it pans 1:1 with the camera (the "map lock"). A real wallpaper/map
// texture lookup goes here later; for now a calm procedural gradient marks the infinite plane.
const Backgrounds = `
fn get_background(uv: vec2<f32>) -> vec3<f32> {
    let camera = vec2<f32>(config._pad1, config._pad2);
    let aspect = config.resolution.x / config.resolution.y;
    let world_pos = vec2<f32>(uv.x * aspect, uv.y) + vec2<f32>(camera.x * aspect, camera.y);
    let pos = world_pos * 0.5;
    let r = sin(pos.x) * 0.5 + 0.5;
    let g = cos(pos.y + 2.0) * 0.5 + 0.5;
    let b = sin(pos.x - pos.y) * 0.5 + 0.5;
    return vec3<f32>(r, g, b) * 0.28 + vec3<f32>(0.08);
}
`;

const MainFragment = `
@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let bg_col = get_background(uv);
    var final_pixel = vec4<f32>(bg_col, 1.0);
    let aspect = config.resolution.x / config.resolution.y;
    let camera = vec2<f32>(config._pad1, config._pad2);

    let total_elements = textureDimensions(ui_data) / 4u;
    for (var idx = 0u; idx < total_elements; idx = idx + 1u) {
        let i = idx * 4u;
        let pt1 = textureLoad(ui_data, i, 0);
        let pt2 = textureLoad(ui_data, i + 1u, 0);
        let pt3 = textureLoad(ui_data, i + 2u, 0);
        let pt4 = textureLoad(ui_data, i + 3u, 0);

        if (pt3.w < 0.5) { continue; }   // active
        if (pt1.z <= 0.0) { continue; }  // width

        let p_pos = pt1.xy;
        let p_size = pt1.zw;
        let p_base_color = pt2;
        let p_z = pt3.x;
        let p_rot = pt3.y;
        let p_element_type = pt3.z;

        let zScale = 1.0 + (p_z * 2.0);
        // Cards (type 2.0) live in world space and obey the camera; chrome (type 3.0) is screen-fixed.
        var camera_offset = vec2<f32>(0.0, 0.0);
        if (p_element_type == 2.0) { camera_offset = camera; }

        let world_center = p_pos + (p_size * 0.5);
        let vp = vec2<f32>(0.5, 0.5);
        let screen_center = vp + (world_center - vp) / zScale - (camera_offset / zScale);

        var pixel_offset = (uv - screen_center) * zScale;
        if (p_rot != 0.0) { pixel_offset = rotate2d(pixel_offset, -p_rot, aspect); }

        let half_extents = p_size * 0.5;
        let height = clamp(1.0 - p_z, 0.0, 1.0);

        // Drop shadow
        let drop_dir = vec2<f32>(0.0, 0.005 + (height * 0.02));
        var shadow_offset = drop_dir;
        if (p_rot != 0.0) { shadow_offset = rotate2d(shadow_offset, -p_rot, aspect); }
        let shadow_blur_radius = max(0.015, height * 0.05);
        let shadow_dist = sdRoundedBox(pixel_offset - shadow_offset, half_extents, 0.02, aspect);
        if (shadow_dist < shadow_blur_radius) {
            var shadow_intensity = 1.0;
            if (shadow_dist > 0.0) { shadow_intensity = 1.0 - smoothstep(0.0, shadow_blur_radius, shadow_dist); }
            final_pixel = mix(final_pixel, vec4<f32>(0.0, 0.0, 0.0, 1.0), shadow_intensity * mix(0.1, 0.25, height));
        }

        let dist = sdRoundedBox(pixel_offset, half_extents, 0.015, aspect);
        if (dist < 0.0) {
            var base_color = p_base_color;
            let inner_uv = vec2<f32>(pixel_offset.x / p_size.x + 0.5, pixel_offset.y / p_size.y + 0.5);

            // subtle vertical bevel so tiles read as physical
            base_color = vec4<f32>(mix(base_color.rgb * 1.12, base_color.rgb * 0.85, inner_uv.y), base_color.a);
            // light inner border
            let inner_bd = sdRoundedBox(pixel_offset, half_extents - vec2<f32>(0.003), 0.015, aspect);
            if (inner_bd > -0.003) { base_color = mix(base_color, vec4<f32>(1.0, 1.0, 1.0, 1.0), 0.12); }

            // aerial fog as the card recedes in depth
            let fogged = mix(base_color.rgb, bg_col, clamp(-p_z * 0.6, 0.0, 1.0));
            final_pixel = mix(final_pixel, vec4<f32>(fogged, base_color.a), base_color.a);
        }
    }

    // keep unused bindings alive (atlases/blitter wired but not sampled in this slice)
    let dummy = textureSampleLevel(emojiAtlas, mySampler, vec2<f32>(0.0), 0.0).r * 1e-7 +
                textureSampleLevel(fontAtlas, mySampler, vec2<f32>(0.0), 0.0).r * 1e-7 +
                textureSampleLevel(chromeAtlas, mySampler, vec2<f32>(0.0), 0.0).r * 1e-7 +
                textureSampleLevel(myTexture, mySampler, vec2<f32>(0.0), 0.0).r * 1e-7 +
                textureSampleLevel(presenterTexture, presenterSampler, vec2<f32>(0.0), 0.0).r * 1e-7;
    return final_pixel + vec4<f32>(0.0, 0.0, 0.0, dummy) * 0.0;
}
`;

export const SHADER = `
${CoreDefinitions}
${MathSDF}
${Backgrounds}
${MainFragment}
`;
