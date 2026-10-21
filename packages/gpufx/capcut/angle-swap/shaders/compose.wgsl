// Angle Swap, pass 1: hard cut from the first clip to the second at the midpoint, with a
// field of twinkling star specks screened on top that swells in and out around the cut.

// 0 -> 1 -> 0 triangle peaking at the cut, with a cubic ease-out.
fn peak(t: f32) -> f32 {
    let tri = select(2.0 - 2.0 * t, 2.0 * t, t < 0.5);
    let r = 1.0 - clamp(tri, 0.0, 1.0);
    return 1.0 - r * r * r;
}

fn hash12(p: vec2f) -> f32 {
    var q = fract(p * vec2f(0.1031, 0.1030));
    q += dot(q, q.yx + 33.33);
    return fract((q.x + q.y) * q.x);
}

fn hash22(p: vec2f) -> vec2f {
    var q = fract(vec3f(p.xyx) * vec3f(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.xx + q.yz) * q.zy);
}

// Star specks on a 405 x 720 portrait sheet: about one cell in six holds a speck.
const SHEET: vec2f = vec2f(405.0, 720.0);
const CELL: f32 = 12.0;

fn specks(sheet_uv: vec2f, frame: f32) -> f32 {
    let px = sheet_uv * SHEET;
    let base = floor(px / CELL);
    var sum = 0.0;
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let cell = base + vec2f(f32(i), f32(j));
            let pick = hash12(cell + 17.0);
            if (pick > 0.16) { continue; }
            let centre = (cell + 0.15 + 0.7 * hash22(cell)) * CELL;
            let size = mix(0.55, 1.5, hash12(cell + 91.0));
            let level = pow(hash12(cell + 53.0), 2.0);
            let twinkle = 0.55 + 0.45 * sin(frame * 0.9 + 6.2831853 * hash12(cell + 7.0));
            let d = length(px - centre);
            sum += level * twinkle * exp(-d * d / (2.0 * size * size));
        }
    }
    return clamp(sum, 0.0, 1.0);
}

// Where the screen pixel lands on the sheet: the sheet covers the frame as a 9:16
// card, turned a quarter for landscape frames.
fn sheet_coord(uv: vec2f) -> vec2f {
    let s = min(globals.size.x, globals.size.y) / 1080.0;
    let w = globals.size.x / s;
    let h = globals.size.y / s;
    let aspect = w / h;
    var card = vec2f(max(w, h * 0.5625), max(w / 0.5625, h));
    var turn = 0.0;
    if (aspect >= (4.0 / 3.0 + 16.0 / 9.0) * 0.5) {
        card = vec2f(max(h, w * 0.5625), max(h / 0.5625, w));
        turn = 1.0;
    }
    let d = (uv - 0.5) * vec2f(w, h);
    let r = select(d, vec2f(d.y, -d.x), turn > 0.5);
    return r / card + 0.5;
}

fn screen(base: vec3f, over: vec3f, amount: f32) -> vec3f {
    return mix(base, 1.0 - (1.0 - base) * (1.0 - over), amount);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    let t = clamp(params.progress, 0.0, 1.0);
    let a = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let b = textureSampleLevel(second, smp, uv, 0.0).rgb;
    let amount = peak(t);
    let frame = floor(t * 43.99);
    let star = vec3f(specks(sheet_coord(uv), frame));
    let picked = select(a, b, t > 0.5);
    gpufx_write(id, vec4f(screen(picked, star, amount), 1.0));
}
