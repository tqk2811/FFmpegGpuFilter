// The first clip rolls up diagonally like a page wound onto a cylinder, its grey back side showing, over the second clip.

const PI: f32 = 3.14159265;
const TAU: f32 = 6.28318531;
// Radius of the rolling cylinder in UV units (one turn = one UV unit of paper).
const RADIUS: f32 = 0.15915494;
// Width in "pixels" of the anti-aliased edges, measured on a 512-unit reference.
const EDGE_SCALE: f32 = 512.0;
// Roll amount at progress 0 and its growth over the transition.
const ROLL_START: f32 = -0.16;
const ROLL_SPAN: f32 = 1.66;
// cos / sin of the 100 degree roll direction.
const C: f32 = -0.1736482;
const S: f32 = 0.9848077;

// Clips are addressed in y-up coordinates; flip back to the texture's top-down rows.
fn clip_a(q: vec2f) -> vec3f { return textureSampleLevel(first, smp, vec2f(q.x, 1.0 - q.y), 0.0).rgb; }
fn clip_b(q: vec2f) -> vec3f { return textureSampleLevel(second, smp, vec2f(q.x, 1.0 - q.y), 0.0).rgb; }

// Into the frame where the roll axis is horizontal.
fn to_roll(q: vec2f) -> vec2f { return vec2f(C * q.x + S * q.y - 0.801, -S * q.x + C * q.y + 0.89); }
// Back to page coordinates.
fn from_roll(q: vec2f) -> vec2f { return vec2f(C * q.x - S * q.y + 0.985, S * q.x + C * q.y + 0.985); }

fn off_page(q: vec2f) -> bool { return q.x < 0.0 || q.y < 0.0 || q.x > 1.0 || q.y > 1.0; }

// Distance from a page point to the nearest page edge (outside: distance to the page).
fn edge_dist(q: vec2f) -> f32 {
    var dx = abs(select(q.x, 1.0 - q.x, q.x > 0.5));
    var dy = abs(select(q.y, 1.0 - q.y, q.y > 0.5));
    if (q.x < 0.0) { dx = -q.x; }
    if (q.x > 1.0) { dx = q.x - 1.0; }
    if (q.y < 0.0) { dy = -q.y; }
    if (q.y > 1.0) { dy = q.y - 1.0; }
    let out_x = q.x < 0.0 || q.x > 1.0;
    let out_y = q.y < 0.0 || q.y > 1.0;
    if (out_x && out_y) { return sqrt(dx * dx + dy * dy); }
    return min(dx, dy);
}

// Edge softening: `inner` well inside, fading toward `outer` with a cubic over 2 units.
fn soften(inner: vec3f, outer: vec3f, dist: f32) -> vec3f {
    let d = dist * EDGE_SCALE;
    if (d > 2.0) { return inner; }
    let w = pow(max(1.0 - d * 0.5, 0.0), 3.0);
    return mix(inner, outer, w);
}

fn arc(x: f32) -> f32 { return asin(clamp(x, -1.0, 1.0)); }

// Flat (unrolled) part of the page seen from the front, or the second clip where it is gone.
fn front_view(uv: vec2f, r: vec2f, dy: f32, roll_angle: f32) -> vec3f {
    let q = from_roll(vec2f(r.x, (PI - (arc(dy / RADIUS) - roll_angle)) / TAU));
    if (dy <= 0.0 && off_page(q)) { return clip_b(uv); }
    if (dy > 0.0) { return clip_a(uv); }
    return soften(clip_a(q), vec3f(0.0), edge_dist(q));
}

// Front view darkened by the soft shadow the cylinder casts near the page edge.
fn front_with_edge_shadow(uv: vec2f, r: vec2f, dy: f32, roll_angle: f32, amount: f32, q: vec2f) -> vec3f {
    var shade = (1.0 - edge_dist(q) * 30.0) / 3.0;
    shade = select(shade * amount, 0.0, shade < 0.0);
    return front_view(uv, r, dy, roll_angle) - vec3f(shade);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let tex_uv = gpufx_uv(id);
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, tex_uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, tex_uv, 0.0).rgb, 1.0)); return; }

    let uv = vec2f(tex_uv.x, 1.0 - tex_uv.y);
    let amount = params.progress * ROLL_SPAN + ROLL_START;
    let roll_angle = TAU * amount;
    let r = to_roll(uv);
    let dy = r.y - amount;
    var col: vec3f;

    if (dy < -RADIUS) {
        // Past the cylinder: second clip, shaded by the rolled page hanging above it.
        let yc = -2.0 * RADIUS - dy;
        let hit = arc(yc / RADIUS) + roll_angle - PI;
        let q = from_roll(vec2f(r.x, hit / TAU));
        var shade = 0.0;
        if (yc < 0.0 && !off_page(q) && (hit < PI || amount > 0.5)) {
            shade = (1.0 - length(q - 0.5) / 0.71) * pow(-yc / RADIUS, 3.0) * 0.5;
        }
        col = clip_b(uv) - vec3f(shade);
    } else if (dy > RADIUS) {
        // Not reached by the roll yet.
        col = clip_a(uv);
    } else {
        // Under the cylinder.
        let hit = arc(dy / RADIUS) + roll_angle - PI;
        let wrapped = hit - TAU * floor(hit / TAU);
        if ((wrapped > PI && amount < 0.5) || (wrapped > PI * 0.5 && amount < 0.0)) {
            col = front_view(uv, r, dy, roll_angle);
        } else {
            let q = from_roll(vec2f(r.x, hit / TAU));
            let shadowed = front_with_edge_shadow(uv, r, dy, roll_angle, amount, q);
            if (off_page(q)) {
                col = shadowed;
            } else {
                // Back of the page: a light grey tinted by the clip's brightness.
                let a = clip_a(q);
                let grey = (a.r + a.g + a.b) / 15.0
                    + 0.8 * (pow(max(1.0 - abs(dy / RADIUS), 0.0), 0.2) * 0.5 + 0.5);
                var beside = clip_a(uv);
                if (dy < 0.0) {
                    // Transparent shadow layer: only its coverage darkens toward black.
                    let cover = (1.0 - length(q - 0.5) / 0.71) * pow(-dy / RADIUS, 3.0) * 0.5;
                    beside = vec3f(0.0) * cover;
                }
                let back = soften(vec3f(grey), beside, RADIUS - abs(dy));
                col = soften(back, shadowed, edge_dist(q));
            }
        }
    }
    gpufx_write(id, vec4f(col, 1.0));
}
