// A swarm of glossy pink heart balloons and soap bubbles pours in from the top and rushes past the camera while the second clip fades in underneath.

// Animation length (s) and frame rate of the balloon flight.
const SPAN = 2.1333333;
const FPS = 30.0;
// The second clip fades in over this span (s).
const FADE_IN = vec2f(0.8333333, 1.1666667);
// Depth slices of the swarm: nearest depth, spacing, count, and camera speed (depth units per s).
const LAYERS = 10;
const NEAR_DEPTH = 0.6;
const DEPTH_STEP = 0.35;
const CAMERA_SPEED = 1.6;
// World size of one swarm cell and lens scale.
const CELL = 0.5;
const LENS = 0.5;
// How far above its resting place (screen units) an item starts as it enters.
const ENTRY_DROP = 0.25;

const HOT = vec3f(0.89, 0.24, 0.50);
const ROSE = vec3f(0.95, 0.52, 0.71);
const PALE = vec3f(0.98, 0.83, 0.90);
const BUBBLE = vec3f(0.68, 0.86, 0.94);

fn hash3(p: vec3f) -> vec4f {
    var q = fract(vec4f(p.xyzx) * vec4f(0.1031, 0.1030, 0.0973, 0.1099));
    q += dot(q, q.wzxy + 33.33);
    return fract((q.xxyz + q.yzzw) * q.zywx);
}

// Signed distance to a unit heart centred on the origin (y up, about 1.1 tall).
fn heart_sd(p0: vec2f) -> f32 {
    var p = vec2f(abs(p0.x), p0.y + 0.55);
    if (p.y + p.x > 1.0) {
        return length(p - vec2f(0.25, 0.75)) - 0.35355339;
    }
    let a = p - vec2f(0.0, 1.0);
    let b = p - 0.5 * max(p.x + p.y, 0.0);
    return sqrt(min(dot(a, a), dot(b, b))) * sign(p.x - p.y);
}

// Premultiplied colour of one swarm item at a screen point, or zero.
fn item(q: vec2f, cell: vec2f, layer: i32, depth: f32, t: f32) -> vec4f {
    let h = hash3(vec3f(cell, f32(layer) * 17.0 + 3.0));
    let h2 = hash3(vec3f(cell + 41.7, f32(layer) * 5.0 + 11.0));
    if (h.x > 0.85) { return vec4f(0.0); }
    let world = (cell + 0.5 + (h.yz - 0.5) * 0.45) * CELL + vec2f(0.0, -0.12 * t);
    var centre = world * LENS / depth;
    // Items arrive from the top of the frame, row by row.
    let arrive = 0.55 * clamp(centre.y + 0.5, 0.0, 1.0) + 0.1 * h2.x;
    let enter = clamp((t - arrive) / 0.12, 0.0, 1.0);
    if (enter <= 0.0) { return vec4f(0.0); }
    centre.y -= ENTRY_DROP * (1.0 - enter) * (1.0 - enter);
    let radius = (0.11 + 0.11 * h.w) * LENS / depth;
    let d = q - centre;
    if (dot(d, d) > 2.0 * radius * radius) { return vec4f(0.0); }
    // Close items fade as they pass the camera.
    let fade = smoothstep(0.12, 0.3, depth) * enter;
    var local = d / radius;
    if (h2.y < 0.07) {
        // Soap bubble: clear body, bright rim and a glint.
        let r = length(local);
        if (r > 0.75) { return vec4f(0.0); }
        let rim = smoothstep(0.45, 0.75, r);
        let glint = smoothstep(0.18, 0.0, length(local - vec2f(-0.3, 0.3)));
        let a = clamp((0.25 + 0.6 * rim + glint) * fade, 0.0, 1.0);
        return vec4f(mix(BUBBLE, vec3f(1.0), glint) * a, a);
    }
    // Tilt and a sideways squash for a turning 3D balloon.
    let ang = (h2.z - 0.5) * 0.8;
    let cs = vec2f(cos(ang), sin(ang));
    local = vec2f(cs.x * local.x + cs.y * local.y, -cs.y * local.x + cs.x * local.y);
    local.x /= 1.1 + 0.15 * cos(6.2831853 * h2.w + 2.0 * t);
    let sd = heart_sd(vec2f(local.x, -local.y));
    if (sd > 0.0) { return vec4f(0.0); }
    // Later, deeper slices carry paler balloons.
    let tone = h2.x + 0.06 * f32(layer);
    var base = HOT;
    if (tone > 0.6) { base = ROSE; }
    if (tone > 0.9) { base = PALE; }
    let body = smoothstep(0.0, 0.3, -sd);
    let spot = exp(-dot(local - vec2f(-0.28, -0.25), local - vec2f(-0.28, -0.25)) * 18.0);
    let shade = base * (0.6 + 0.4 * body) + vec3f(0.35) * spot;
    let a = smoothstep(0.0, 0.03, -sd) * fade;
    return vec4f(min(shade, vec3f(1.0)) * a, a);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends, so cutting in and out of the transition never jumps.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clamp(params.progress, 0.0, 1.0) * SPAN;

    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    var color = mix(a, b, clamp((t - FADE_IN.x) / (FADE_IN.y - FADE_IN.x), 0.0, 1.0));

    // Square swarm view that covers the frame; y grows downward.
    let size = globals.size;
    let q = (uv - 0.5) * size / max(size.x, size.y);
    let camera = CAMERA_SPEED * t;
    // The swarm thins out before the clip ends, leaving the second clip clean.
    let tail = 1.0 - smoothstep(1.92, 2.0, t);
    // Far slices first, near slices on top.
    for (var layer = LAYERS - 1; layer >= 0; layer--) {
        let depth = NEAR_DEPTH + DEPTH_STEP * f32(layer) - camera;
        if (depth < 0.12) { continue; }
        let world = q * depth / LENS + vec2f(0.0, 0.12 * t);
        let home = floor(world / CELL);
        // Entering items drop in from above by up to ENTRY_DROP screen units, so also
        // search the rows below that many cells away on this slice.
        let below = i32(ceil(ENTRY_DROP * depth / (LENS * CELL)));
        for (var j = -1; j <= 1 + below; j++) {
            for (var i = -1; i <= 1; i++) {
                let c = item(q, home + vec2f(f32(i), f32(j)), layer, depth, t);
                color = c.rgb * tail + color * (1.0 - c.a * tail);
            }
        }
    }

    // One misty frame as the camera bursts through a balloon.
    let frame = i32(floor(t * FPS + 0.5));
    if (frame == 52) {
        color = mix(color, vec3f(0.80, 0.88, 0.94), 0.55 + 0.25 * uv.y);
    }
    gpufx_write(id, vec4f(color, 1.0));
}
