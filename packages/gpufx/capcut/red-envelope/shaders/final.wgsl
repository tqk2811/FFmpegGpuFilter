// Red Envelope, last pass: the glowing second clip pops out of a red envelope that tumbles in, gets tapped and tears open over the first clip.

// The animation runs over two seconds of scene time.
const SPAN: f32 = 2.0;

fn clock() -> f32 { return clamp(params.progress, 0.0, 1.0) * SPAN; }

// Cubic Bezier easing through (0,0), (x1,y1), (x2,y2), (1,1), solved for x by bisection.
fn bezier_ease(x: f32, c: vec4f) -> f32 {
    var lo = 0.0;
    var hi = 1.0;
    for (var i = 0; i < 20; i++) {
        let s = 0.5 * (lo + hi);
        let inv = 1.0 - s;
        let bx = 3.0 * inv * inv * s * c.x + 3.0 * inv * s * s * c.z + s * s * s;
        if (bx > x) { hi = s; } else { lo = s; }
    }
    let s = 0.5 * (lo + hi);
    let inv = 1.0 - s;
    return 3.0 * inv * inv * s * c.y + 3.0 * inv * s * s * c.w + s * s * s;
}

const SOFT: vec4f = vec4f(0.166667, 0.166667, 0.833333, 0.833333);

// The glow pulses twice: off at the keys 1.0 and 1.466667 / 1.966667, full at 1.3 and 1.8.
// Returns 0 (glow off) .. 1 (glow full) along that pulse train.
fn pulse(t: f32) -> f32 {
    let keys = array<f32, 6>(1.0, 1.166667, 1.3, 1.466667, 1.8, 1.966667);
    let vals = array<f32, 6>(0.0, 0.0, 1.0, 0.0, 1.0, 0.0);
    if (t < keys[0] || t >= keys[5]) { return 0.0; }
    var k = 0;
    for (var i = 0; i < 5; i++) { if (t >= keys[i]) { k = i; } }
    let x = clamp((t - keys[k]) / (keys[k + 1] - keys[k]), 0.0, 1.0);
    return mix(vals[k], vals[k + 1], bezier_ease(x, SOFT));
}

fn glow_threshold(t: f32) -> f32 { return 1.0 - pulse(t); }
fn glow_radius(t: f32) -> f32 { return 100.0 * pulse(t); }
fn glow_gain(t: f32) -> f32 { return 2.0 * pulse(t); }

// Envelope outline, traced once per 30 fps frame of the 2 s animation, in a square frame
// (0..1, y down) that covers the output. A frame lists pieces (first, count); each piece
// is a polygon (first vertex, count) plus a box (centre, half-width axis, half-height axis)
// that lays out its print. POINTER holds the tapping hand: centre and height (0 = hidden).

const FRAME_PIECES = array<vec2i, 60>(vec2i(0, 1), vec2i(1, 1), vec2i(2, 1), vec2i(3, 1), vec2i(4, 1), vec2i(5, 1), vec2i(6, 1), vec2i(7, 1), vec2i(8, 1), vec2i(9, 1), vec2i(10, 1), vec2i(11, 1), vec2i(12, 1), vec2i(13, 1), vec2i(14, 1), vec2i(15, 1), vec2i(16, 1), vec2i(17, 1), vec2i(18, 1), vec2i(19, 1), vec2i(20, 1), vec2i(21, 1), vec2i(22, 1), vec2i(23, 1), vec2i(24, 1), vec2i(25, 1), vec2i(26, 1), vec2i(27, 1), vec2i(28, 1), vec2i(29, 1), vec2i(30, 1), vec2i(31, 1), vec2i(32, 2), vec2i(34, 2), vec2i(36, 2), vec2i(38, 2), vec2i(40, 2), vec2i(42, 2), vec2i(44, 2), vec2i(46, 2), vec2i(48, 2), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0), vec2i(50, 0));
const PIECE_VERTS = array<vec2i, 50>(vec2i(0, 3), vec2i(3, 3), vec2i(6, 4), vec2i(10, 6), vec2i(16, 5), vec2i(21, 6), vec2i(27, 7), vec2i(34, 8), vec2i(42, 9), vec2i(51, 9), vec2i(60, 5), vec2i(65, 7), vec2i(72, 6), vec2i(78, 5), vec2i(83, 7), vec2i(90, 5), vec2i(95, 12), vec2i(107, 12), vec2i(119, 4), vec2i(123, 4), vec2i(127, 4), vec2i(131, 4), vec2i(135, 4), vec2i(139, 4), vec2i(143, 4), vec2i(147, 4), vec2i(151, 4), vec2i(155, 4), vec2i(159, 4), vec2i(163, 4), vec2i(167, 11), vec2i(178, 12), vec2i(190, 9), vec2i(199, 12), vec2i(211, 12), vec2i(223, 12), vec2i(235, 11), vec2i(246, 10), vec2i(256, 9), vec2i(265, 12), vec2i(277, 10), vec2i(287, 11), vec2i(298, 7), vec2i(305, 12), vec2i(317, 12), vec2i(329, 9), vec2i(338, 11), vec2i(349, 11), vec2i(360, 6), vec2i(366, 7));
const OUTLINE = array<vec2f, 373>(vec2f(0.6250, 0.9980), vec2f(0.5566, 0.9121), vec2f(0.4453, 0.9980), vec2f(0.6309, 0.9980), vec2f(0.5547, 0.9043), vec2f(0.4414, 0.9980), vec2f(0.6387, 0.9980), vec2f(0.5469, 0.8848), vec2f(0.5215, 0.9082), vec2f(0.4395, 0.9961), vec2f(0.5273, 0.8574), vec2f(0.5234, 0.8574), vec2f(0.4531, 0.9980), vec2f(0.5723, 0.9980), vec2f(0.5723, 0.9922), vec2f(0.5879, 0.9570), vec2f(0.4941, 0.8262), vec2f(0.4883, 0.8926), vec2f(0.4922, 0.9980), vec2f(0.5078, 0.9980), vec2f(0.4980, 0.8262), vec2f(0.3809, 0.8926), vec2f(0.4316, 0.9824), vec2f(0.4375, 0.9980), vec2f(0.6035, 0.9980), vec2f(0.4766, 0.7949), vec2f(0.4727, 0.7949), vec2f(0.3359, 0.8809), vec2f(0.3379, 0.8867), vec2f(0.4297, 0.9902), vec2f(0.4316, 0.9980), vec2f(0.6797, 0.9980), vec2f(0.4785, 0.7578), vec2f(0.4707, 0.7617), vec2f(0.4922, 0.7129), vec2f(0.4238, 0.8535), vec2f(0.4238, 0.8594), vec2f(0.4785, 0.9902), vec2f(0.4785, 0.9980), vec2f(0.5605, 0.9980), vec2f(0.5762, 0.9492), vec2f(0.4961, 0.7129), vec2f(0.5000, 0.6641), vec2f(0.4961, 0.6660), vec2f(0.4043, 0.9219), vec2f(0.4043, 0.9297), vec2f(0.4316, 0.9785), vec2f(0.4395, 0.9980), vec2f(0.5059, 0.9980), vec2f(0.5918, 0.7930), vec2f(0.5918, 0.7871), vec2f(0.4883, 0.6172), vec2f(0.4844, 0.6191), vec2f(0.3125, 0.9414), vec2f(0.3125, 0.9453), vec2f(0.4004, 0.9902), vec2f(0.4043, 0.9980), vec2f(0.4941, 0.9980), vec2f(0.4941, 0.9922), vec2f(0.6484, 0.7031), vec2f(0.4824, 0.5703), vec2f(0.3887, 0.9551), vec2f(0.4961, 0.9844), vec2f(0.5723, 0.6309), vec2f(0.4883, 0.5703), vec2f(0.5137, 0.5234), vec2f(0.5000, 0.5312), vec2f(0.4531, 0.5781), vec2f(0.4863, 0.8535), vec2f(0.4922, 0.9297), vec2f(0.5039, 0.9297), vec2f(0.5645, 0.9160), vec2f(0.5449, 0.4785), vec2f(0.3809, 0.5273), vec2f(0.3809, 0.5352), vec2f(0.4727, 0.8828), vec2f(0.6465, 0.8477), vec2f(0.6152, 0.7266), vec2f(0.5508, 0.4395), vec2f(0.3887, 0.4766), vec2f(0.4609, 0.8438), vec2f(0.4688, 0.8438), vec2f(0.6152, 0.7871), vec2f(0.5215, 0.4062), vec2f(0.5137, 0.4062), vec2f(0.4590, 0.4238), vec2f(0.4766, 0.7812), vec2f(0.4805, 0.8086), vec2f(0.4980, 0.7930), vec2f(0.5371, 0.7480), vec2f(0.4746, 0.3770), vec2f(0.4648, 0.7207), vec2f(0.5176, 0.7695), vec2f(0.5234, 0.7695), vec2f(0.5371, 0.3809), vec2f(0.4375, 0.3496), vec2f(0.4238, 0.7031), vec2f(0.5586, 0.7344), vec2f(0.5645, 0.6523), vec2f(0.5391, 0.6504), vec2f(0.5078, 0.5742), vec2f(0.5312, 0.5781), vec2f(0.5410, 0.5156), vec2f(0.5547, 0.5234), vec2f(0.5566, 0.5469), vec2f(0.5703, 0.5508), vec2f(0.5781, 0.3477), vec2f(0.5918, 0.3242), vec2f(0.4180, 0.3281), vec2f(0.4082, 0.6895), vec2f(0.5820, 0.7031), vec2f(0.5840, 0.6270), vec2f(0.5762, 0.6465), vec2f(0.5215, 0.6465), vec2f(0.4883, 0.5684), vec2f(0.5117, 0.5703), vec2f(0.5195, 0.5117), vec2f(0.5371, 0.5410), vec2f(0.5859, 0.5625), vec2f(0.4082, 0.3125), vec2f(0.4062, 0.6816), vec2f(0.5879, 0.6855), vec2f(0.5918, 0.3125), vec2f(0.4082, 0.3066), vec2f(0.4062, 0.6777), vec2f(0.5898, 0.6777), vec2f(0.5918, 0.3086), vec2f(0.4102, 0.3105), vec2f(0.4082, 0.6719), vec2f(0.5879, 0.6738), vec2f(0.5879, 0.3105), vec2f(0.4141, 0.3184), vec2f(0.4141, 0.6621), vec2f(0.5840, 0.6621), vec2f(0.5840, 0.3184), vec2f(0.4199, 0.3262), vec2f(0.4199, 0.6465), vec2f(0.5781, 0.6465), vec2f(0.5781, 0.3262), vec2f(0.4258, 0.3340), vec2f(0.4238, 0.6348), vec2f(0.5742, 0.6348), vec2f(0.5742, 0.3359), vec2f(0.4258, 0.3379), vec2f(0.4258, 0.6289), vec2f(0.5703, 0.6309), vec2f(0.5723, 0.3379), vec2f(0.4258, 0.3340), vec2f(0.4238, 0.6348), vec2f(0.5742, 0.6348), vec2f(0.5742, 0.3359), vec2f(0.4199, 0.3262), vec2f(0.4199, 0.6465), vec2f(0.5781, 0.6465), vec2f(0.5781, 0.3262), vec2f(0.4141, 0.3184), vec2f(0.4141, 0.6621), vec2f(0.5840, 0.6621), vec2f(0.5840, 0.3184), vec2f(0.4102, 0.3105), vec2f(0.4082, 0.6719), vec2f(0.5879, 0.6738), vec2f(0.5879, 0.3105), vec2f(0.4082, 0.3066), vec2f(0.4062, 0.6777), vec2f(0.5898, 0.6777), vec2f(0.5918, 0.3086), vec2f(0.6133, 0.3164), vec2f(0.5234, 0.3066), vec2f(0.5195, 0.3457), vec2f(0.5137, 0.3477), vec2f(0.5117, 0.3672), vec2f(0.5020, 0.3691), vec2f(0.4980, 0.3125), vec2f(0.4102, 0.3125), vec2f(0.4102, 0.6797), vec2f(0.5879, 0.6816), vec2f(0.5879, 0.5176), vec2f(0.6289, 0.3203), vec2f(0.5410, 0.3027), vec2f(0.4941, 0.5254), vec2f(0.4863, 0.3086), vec2f(0.3945, 0.3145), vec2f(0.4023, 0.6816), vec2f(0.5957, 0.6816), vec2f(0.5977, 0.5977), vec2f(0.5176, 0.6328), vec2f(0.4922, 0.5508), vec2f(0.5566, 0.5020), vec2f(0.5996, 0.5645), vec2f(0.4375, 0.2949), vec2f(0.3496, 0.3242), vec2f(0.3652, 0.3828), vec2f(0.3828, 0.6855), vec2f(0.4746, 0.6797), vec2f(0.4707, 0.6133), vec2f(0.4668, 0.6113), vec2f(0.4688, 0.5781), vec2f(0.4551, 0.3496), vec2f(0.5918, 0.2930), vec2f(0.5527, 0.3730), vec2f(0.5215, 0.6797), vec2f(0.6172, 0.6855), vec2f(0.6230, 0.6055), vec2f(0.5820, 0.6445), vec2f(0.5312, 0.6172), vec2f(0.5391, 0.5410), vec2f(0.5645, 0.5488), vec2f(0.5938, 0.5039), vec2f(0.6250, 0.5684), vec2f(0.6758, 0.3340), vec2f(0.3555, 0.2871), vec2f(0.2793, 0.3398), vec2f(0.3125, 0.4004), vec2f(0.3496, 0.6914), vec2f(0.4336, 0.6816), vec2f(0.4414, 0.6738), vec2f(0.4121, 0.4160), vec2f(0.4043, 0.4062), vec2f(0.3984, 0.3691), vec2f(0.4023, 0.3594), vec2f(0.3945, 0.3555), vec2f(0.3887, 0.3340), vec2f(0.6797, 0.2891), vec2f(0.6152, 0.3594), vec2f(0.5625, 0.5801), vec2f(0.5957, 0.5254), vec2f(0.6699, 0.5137), vec2f(0.6641, 0.5996), vec2f(0.5977, 0.6348), vec2f(0.5625, 0.6016), vec2f(0.5566, 0.6797), vec2f(0.6523, 0.6875), vec2f(0.6934, 0.4473), vec2f(0.7480, 0.3555), vec2f(0.2559, 0.2910), vec2f(0.1934, 0.3652), vec2f(0.2363, 0.4043), vec2f(0.2559, 0.4453), vec2f(0.3047, 0.6934), vec2f(0.3164, 0.6973), vec2f(0.3926, 0.6816), vec2f(0.4004, 0.6738), vec2f(0.3438, 0.4043), vec2f(0.3184, 0.3594), vec2f(0.3203, 0.3496), vec2f(0.7852, 0.3008), vec2f(0.7148, 0.3398), vec2f(0.6777, 0.3867), vec2f(0.6230, 0.5449), vec2f(0.6641, 0.5156), vec2f(0.6797, 0.5176), vec2f(0.6777, 0.5391), vec2f(0.7324, 0.5332), vec2f(0.7773, 0.4258), vec2f(0.8340, 0.3828), vec2f(0.1543, 0.2988), vec2f(0.1055, 0.3848), vec2f(0.1562, 0.4199), vec2f(0.1816, 0.4590), vec2f(0.2539, 0.7051), vec2f(0.3496, 0.6777), vec2f(0.2617, 0.3984), vec2f(0.2285, 0.3574), vec2f(0.2305, 0.3477), vec2f(0.8906, 0.3164), vec2f(0.8438, 0.3281), vec2f(0.7812, 0.3691), vec2f(0.7363, 0.4355), vec2f(0.7012, 0.5234), vec2f(0.7500, 0.5176), vec2f(0.7559, 0.5332), vec2f(0.7441, 0.5410), vec2f(0.7969, 0.5645), vec2f(0.8457, 0.4590), vec2f(0.8848, 0.4238), vec2f(0.9258, 0.4082), vec2f(0.0527, 0.3105), vec2f(0.0098, 0.4023), vec2f(0.0547, 0.4238), vec2f(0.0957, 0.4688), vec2f(0.1953, 0.7148), vec2f(0.2852, 0.6816), vec2f(0.2891, 0.6699), vec2f(0.1758, 0.4043), vec2f(0.1426, 0.3711), vec2f(0.1367, 0.3516), vec2f(0.9980, 0.3340), vec2f(0.8594, 0.3945), vec2f(0.7852, 0.5098), vec2f(0.8320, 0.5371), vec2f(0.8125, 0.5547), vec2f(0.8418, 0.6074), vec2f(0.7422, 0.5977), vec2f(0.7109, 0.6777), vec2f(0.8066, 0.7188), vec2f(0.9258, 0.4844), vec2f(0.9980, 0.4395), vec2f(0.0000, 0.3457), vec2f(0.0000, 0.4844), vec2f(0.1387, 0.7266), vec2f(0.2266, 0.6738), vec2f(0.0820, 0.4121), vec2f(0.0410, 0.3770), vec2f(0.0352, 0.3594), vec2f(0.9980, 0.3809), vec2f(0.9648, 0.4004), vec2f(0.9180, 0.4492), vec2f(0.8613, 0.5312), vec2f(0.8320, 0.5625), vec2f(0.8027, 0.6328), vec2f(0.7832, 0.6562), vec2f(0.7734, 0.6562), vec2f(0.7715, 0.6758), vec2f(0.8711, 0.7285), vec2f(0.9629, 0.5762), vec2f(0.9980, 0.5371), vec2f(0.0000, 0.4395), vec2f(0.0000, 0.6406), vec2f(0.0078, 0.6445), vec2f(0.0723, 0.7383), vec2f(0.1602, 0.6758), vec2f(0.1367, 0.6484), vec2f(0.1211, 0.6191), vec2f(0.1113, 0.6133), vec2f(0.1074, 0.5977), vec2f(0.0527, 0.5117), vec2f(0.0352, 0.4961), vec2f(0.0352, 0.4863), vec2f(0.9980, 0.4805), vec2f(0.9531, 0.5312), vec2f(0.9121, 0.5684), vec2f(0.9023, 0.5957), vec2f(0.8574, 0.6562), vec2f(0.8418, 0.6562), vec2f(0.8418, 0.6777), vec2f(0.9336, 0.7402), vec2f(0.9980, 0.6641), vec2f(0.0000, 0.5625), vec2f(0.0000, 0.7461), vec2f(0.0098, 0.7480), vec2f(0.0879, 0.6855), vec2f(0.0938, 0.6758), vec2f(0.0723, 0.6523), vec2f(0.0664, 0.6504), vec2f(0.0645, 0.6406), vec2f(0.0508, 0.6250), vec2f(0.0332, 0.6113), vec2f(0.0312, 0.5996), vec2f(0.9961, 0.5684), vec2f(0.9902, 0.5723), vec2f(0.9805, 0.5879), vec2f(0.9785, 0.5996), vec2f(0.9590, 0.6250), vec2f(0.9434, 0.6367), vec2f(0.9219, 0.6621), vec2f(0.9082, 0.6582), vec2f(0.9102, 0.6738), vec2f(0.9043, 0.6758), vec2f(0.9980, 0.7500), vec2f(0.0000, 0.6426), vec2f(0.0000, 0.7129), vec2f(0.0352, 0.6797), vec2f(0.0195, 0.6699), vec2f(0.0195, 0.6621), vec2f(0.0059, 0.6543), vec2f(0.9980, 0.6523), vec2f(0.9863, 0.6641), vec2f(0.9746, 0.6641), vec2f(0.9688, 0.6602), vec2f(0.9707, 0.6738), vec2f(0.9648, 0.6758), vec2f(0.9961, 0.7051));
const PIECE_FRAME = array<vec4f, 100>(vec4f(0.5352, 0.9551, 0.0000, 0.0430), vec4f(-0.0898, 0.0000, 0.0, 0.0), vec4f(0.5361, 0.9512, 0.0000, 0.0469), vec4f(-0.0947, 0.0000, 0.0, 0.0), vec4f(0.5391, 0.9414, 0.0000, 0.0566), vec4f(-0.0996, 0.0000, 0.0, 0.0), vec4f(0.5359, 0.9506, 0.0480, 0.0240), vec4f(-0.0355, 0.0711, 0.0, 0.0), vec4f(0.4950, 0.9124, 0.0084, -0.0004), vec4f(0.0045, 0.0861, 0.0, 0.0), vec4f(0.4801, 0.9324, 0.0601, -0.0372), vec4f(0.0636, 0.1027, 0.0, 0.0), vec4f(0.5060, 0.9382, 0.0729, -0.0615), vec4f(0.1016, 0.1206, 0.0, 0.0), vec4f(0.4882, 0.8684, 0.0550, -0.0187), vec4f(0.0469, 0.1383, 0.0, 0.0), vec4f(0.5030, 0.8430, 0.0628, 0.0225), vec4f(-0.0565, 0.1576, 0.0, 0.0), vec4f(0.4800, 0.8252, 0.0827, 0.0439), vec4f(-0.0883, 0.1662, 0.0, 0.0), vec4f(0.4886, 0.7767, 0.0548, 0.0131), vec4f(-0.0465, 0.1953, 0.0, 0.0), vec4f(0.5070, 0.7265, 0.0371, -0.0041), vec4f(0.0224, 0.2003, 0.0, 0.0), vec4f(0.5124, 0.6850, 0.0864, -0.0230), vec4f(0.0494, 0.1853, 0.0, 0.0), vec4f(0.5054, 0.6419, 0.0823, -0.0161), vec4f(0.0368, 0.1875, 0.0, 0.0), vec4f(0.4990, 0.6074, 0.0327, -0.0016), vec4f(0.0095, 0.2000, 0.0, 0.0), vec4f(0.4991, 0.5728, 0.0316, 0.0011), vec4f(-0.0068, 0.1958, 0.0, 0.0), vec4f(0.5001, 0.5379, 0.0710, 0.0032), vec4f(-0.0088, 0.1934, 0.0, 0.0), vec4f(0.4998, 0.5117, 0.0884, 0.0023), vec4f(-0.0049, 0.1897, 0.0, 0.0), vec4f(0.4991, 0.4983, 0.0925, 0.0008), vec4f(-0.0016, 0.1865, 0.0, 0.0), vec4f(0.4990, 0.4922, 0.0928, -0.0000), vec4f(0.0000, 0.1855, 0.0, 0.0), vec4f(0.4980, 0.4922, 0.0898, -0.0000), vec4f(0.0000, 0.1816, 0.0, 0.0), vec4f(0.4990, 0.4902, 0.0850, -0.0000), vec4f(0.0000, 0.1719, 0.0, 0.0), vec4f(0.4990, 0.4863, 0.0791, -0.0000), vec4f(0.0000, 0.1602, 0.0, 0.0), vec4f(0.4990, 0.4844, 0.0752, -0.0000), vec4f(0.0000, 0.1504, 0.0, 0.0), vec4f(0.4990, 0.4844, 0.0732, -0.0000), vec4f(0.0000, 0.1465, 0.0, 0.0), vec4f(0.4990, 0.4844, 0.0752, -0.0000), vec4f(0.0000, 0.1504, 0.0, 0.0), vec4f(0.4990, 0.4863, 0.0791, -0.0000), vec4f(0.0000, 0.1602, 0.0, 0.0), vec4f(0.4990, 0.4902, 0.0850, -0.0000), vec4f(0.0000, 0.1719, 0.0, 0.0), vec4f(0.4980, 0.4922, 0.0898, -0.0000), vec4f(0.0000, 0.1816, 0.0, 0.0), vec4f(0.4990, 0.4922, 0.0928, -0.0000), vec4f(0.0000, 0.1855, 0.0, 0.0), vec4f(0.5117, 0.4941, 0.1016, 0.0000), vec4f(-0.0000, 0.1875, 0.0, 0.0), vec4f(0.5117, 0.4922, 0.1172, -0.0000), vec4f(0.0000, 0.1895, 0.0, 0.0), vec4f(0.4159, 0.4913, 0.0513, -0.0045), vec4f(0.0169, 0.1930, 0.0, 0.0), vec4f(0.5912, 0.4917, 0.0570, 0.0094), vec4f(-0.0320, 0.1942, 0.0, 0.0), vec4f(0.3686, 0.4896, 0.0576, -0.0116), vec4f(0.0397, 0.1971, 0.0, 0.0), vec4f(0.6419, 0.4912, 0.0619, 0.0178), vec4f(-0.0567, 0.1967, 0.0, 0.0), vec4f(0.3052, 0.4928, 0.0615, -0.0209), vec4f(0.0665, 0.1959, 0.0, 0.0), vec4f(0.7219, 0.4349, 0.0528, 0.0357), vec4f(-0.0820, 0.1214, 0.0, 0.0), vec4f(0.2327, 0.4973, 0.0618, -0.0286), vec4f(0.0896, 0.1933, 0.0, 0.0), vec4f(0.8144, 0.4352, 0.0530, 0.0437), vec4f(-0.0892, 0.1081, 0.0, 0.0), vec4f(0.1534, 0.5054, 0.0609, -0.0362), vec4f(0.1117, 0.1882, 0.0, 0.0), vec4f(0.8623, 0.5112, 0.0589, 0.0404), vec4f(-0.1260, 0.1839, 0.0, 0.0), vec4f(0.0866, 0.5273, 0.0484, -0.0266), vec4f(0.0968, 0.1760, 0.0, 0.0), vec4f(0.9157, 0.5488, 0.0518, 0.0344), vec4f(-0.1025, 0.1546, 0.0, 0.0), vec4f(0.0351, 0.5895, 0.0480, -0.0314), vec4f(0.0793, 0.1211, 0.0, 0.0), vec4f(0.9595, 0.6107, 0.0495, 0.0396), vec4f(-0.0786, 0.0983, 0.0, 0.0), vec4f(0.0469, 0.6553, 0.0469, 0.0000), vec4f(-0.0000, 0.0928, 0.0, 0.0), vec4f(0.9512, 0.6592, 0.0469, -0.0000), vec4f(0.0000, 0.0908, 0.0, 0.0), vec4f(0.0176, 0.6777, 0.0176, 0.0000), vec4f(-0.0000, 0.0352, 0.0, 0.0), vec4f(0.9814, 0.6787, 0.0166, -0.0000), vec4f(0.0000, 0.0264, 0.0, 0.0));
const POINTER = array<vec3f, 60>(vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.9885, 0.7465, 0.0410), vec3f(0.9797, 0.7356, 0.1172), vec3f(0.9589, 0.7280, 0.1113), vec3f(0.9193, 0.7145, 0.1152), vec3f(0.8766, 0.7001, 0.1133), vec3f(0.8324, 0.6862, 0.1133), vec3f(0.7875, 0.6714, 0.1113), vec3f(0.7435, 0.6564, 0.1133), vec3f(0.7009, 0.6424, 0.1134), vec3f(0.6606, 0.6297, 0.1133), vec3f(0.6239, 0.6171, 0.1138), vec3f(0.5921, 0.6070, 0.1113), vec3f(0.5648, 0.5983, 0.1133), vec3f(0.5444, 0.5908, 0.1133), vec3f(0.5317, 0.5873, 0.1113), vec3f(0.5270, 0.5850, 0.1133), vec3f(0.5267, 0.5857, 0.1094), vec3f(0.5263, 0.5843, 0.1055), vec3f(0.5263, 0.5832, 0.0977), vec3f(0.5260, 0.5824, 0.0929), vec3f(0.5259, 0.5828, 0.0898), vec3f(0.5260, 0.5824, 0.0929), vec3f(0.5263, 0.5832, 0.0977), vec3f(0.5263, 0.5843, 0.1055), vec3f(0.5267, 0.5857, 0.1094), vec3f(0.5270, 0.5850, 0.1133), vec3f(0.5334, 0.5853, 0.1152), vec3f(0.5516, 0.5853, 0.1172), vec3f(0.5796, 0.5840, 0.1133), vec3f(0.6163, 0.5803, 0.0977), vec3f(0.6611, 0.5738, 0.0832), vec3f(0.7138, 0.5648, 0.0781), vec3f(0.7738, 0.5557, 0.0859), vec3f(0.8247, 0.5344, 0.0762), vec3f(0.8998, 0.5356, 0.0840), vec3f(0.9606, 0.5464, 0.0977), vec3f(0.9809, 0.5574, 0.0703), vec3f(0.9904, 0.5558, 0.0137), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000), vec3f(0.0000, 0.0000, 0.0000));


const PAPER: vec3f = vec3f(0.69, 0.23, 0.2);
const PAPER_DARK: vec3f = vec3f(0.55, 0.16, 0.15);
const GOLD: vec3f = vec3f(0.93, 0.76, 0.38);

// Layer scale of the second clip (1 = full frame): hidden until 1.1 s, then 0.3638 -> 2.4707 -> 1.
fn clip_scale(t: f32) -> f32 {
    if (t < 1.1) { return 0.0; }
    if (t < 1.666667) {
        return mix(0.3638, 2.470664, bezier_ease((t - 1.1) / 0.566667, vec4f(0.222253, 0.174466, 0.577018, 0.925339)));
    }
    if (t < 1.966667) {
        return mix(2.470664, 1.0, bezier_ease((t - 1.666667) / 0.3, vec4f(0.514081, -0.068821, 0.666667, 1.0)));
    }
    return 1.0;
}

// Second clip with its glow added on top.
fn glowing_second(q: vec2f, gain: f32) -> vec3f {
    let base = textureSampleLevel(second, smp, q, 0.0).rgb;
    var g = textureSampleLevel(glow_v, smp, q, 0.0) * gain;
    if (g.a > 1.0) { g = g / g.a; }
    return base + g.rgb;
}

fn segment_distance(p: vec2f, a: vec2f, b: vec2f) -> f32 {
    let ab = b - a;
    let h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-12), 0.0, 1.0);
    return length(p - a - ab * h);
}

// Signed distance to a piece outline (negative inside), even-odd fill.
fn piece_distance(p: vec2f, piece: i32) -> f32 {
    let span = PIECE_VERTS[piece];
    var d = 1e9;
    var inside = false;
    for (var i = 0; i < span.y; i++) {
        let a = OUTLINE[span.x + i];
        let b = OUTLINE[span.x + (i + 1) % span.y];
        d = min(d, segment_distance(p, a, b));
        if ((a.y > p.y) != (b.y > p.y)) {
            let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x);
            if (p.x < x) { inside = !inside; }
        }
    }
    return select(d, -d, inside);
}

// Print of the envelope paper at box coordinates l (-1..1 across and down). `hole` is the
// across-position of the coin centre (0 whole envelope, +-1 for a torn half).
fn paper_print(l: vec2f, hole: f32, aspect: f32) -> vec3f {
    var c = PAPER;
    // Faint concentric cloud rings.
    let ring = sin(length(vec2f(l.x * aspect, l.y) - vec2f(0.3, 0.5)) * 26.0);
    c = mix(c, PAPER_DARK, 0.25 * smoothstep(0.85, 1.0, ring));
    // Darker rim along the paper edge.
    c = mix(c, PAPER_DARK, smoothstep(0.82, 1.0, max(abs(l.x), abs(l.y))) * 0.6);
    // A gold coin with a square hole.
    let q = vec2f((l.x - hole) * aspect, l.y + 0.1);
    let r = length(q);
    let coin = smoothstep(0.62, 0.58, r) * smoothstep(0.44, 0.48, r);
    let sq = max(abs(q.x), abs(q.y));
    let inner = smoothstep(0.24, 0.2, sq) * smoothstep(0.1, 0.14, sq);
    c = mix(c, GOLD, max(coin, inner));
    return c;
}

// Pointing hand cursor, height 1, origin at its centre, y down. Returns signed distance.
fn hand_distance(p: vec2f) -> f32 {
    let f = abs(p - vec2f(-0.12, -0.18)) - vec2f(0.06, 0.24);
    let finger = length(max(f, vec2f(0.0))) + min(max(f.x, f.y), 0.0) - 0.04;
    let b = abs(p - vec2f(0.04, 0.2)) - vec2f(0.2, 0.17);
    let palm = length(max(b, vec2f(0.0))) + min(max(b.x, b.y), 0.0) - 0.08;
    return min(finger, palm);
}

// Envelope and hand of animation frame `frame` at square-frame position p: premultiplied colour.
fn envelope(p: vec2f, frame: i32, px: f32) -> vec4f {
    var acc = vec4f(0.0);
    let span = FRAME_PIECES[frame];
    for (var k = 0; k < span.y; k++) {
        let piece = span.x + k;
        let d = piece_distance(p, piece);
        let cover = clamp(0.5 - d / px, 0.0, 1.0);
        if (cover <= 0.0) { continue; }
        let box0 = PIECE_FRAME[2 * piece];
        let box1 = PIECE_FRAME[2 * piece + 1];
        let ax = box0.zw;
        let ay = box1.xy;
        let rel = p - box0.xy;
        let l = vec2f(dot(rel, ax) / max(dot(ax, ax), 1e-8), dot(rel, ay) / max(dot(ay, ay), 1e-8));
        var hole = 0.0;
        if (span.y == 2) { hole = select(-1.0, 1.0, k == 0); }
        let aspect = length(ax) / max(length(ay), 1e-6);
        let c = paper_print(l, hole, aspect);
        acc = vec4f(c * cover, cover) + acc * (1.0 - cover);
    }
    let hand = POINTER[frame];
    if (hand.z > 0.0) {
        let d = hand_distance((p - hand.xy) / hand.z) * hand.z;
        let fill = clamp(0.5 - d / px, 0.0, 1.0);
        let body = clamp(0.5 - (d + 0.04 * hand.z) / px, 0.0, 1.0);
        let c = mix(vec3f(0.3), vec3f(0.95), body);
        acc = vec4f(c * fill, fill) + acc * (1.0 - fill);
    }
    return acc;
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (!gpufx_in_bounds(id)) { return; }
    let uv = gpufx_uv(id);
    // Exact clips at the ends of the transition.
    if (params.progress <= 0.0) { gpufx_write(id, vec4f(textureSampleLevel(first, smp, uv, 0.0).rgb, 1.0)); return; }
    if (params.progress >= 1.0) { gpufx_write(id, vec4f(textureSampleLevel(second, smp, uv, 0.0).rgb, 1.0)); return; }
    let t = clock();

    var color = textureSampleLevel(first, smp, uv, 0.0).rgb;
    let s = clip_scale(t);
    if (s > 0.0) {
        let q = 0.5 + (uv - 0.5) / s;
        if (all(q >= vec2f(0.0)) && all(q <= vec2f(1.0))) {
            color = glowing_second(q, glow_gain(t));
        }
    }

    // The square envelope animation covers the frame, centred.
    let aspect = globals.size.x / globals.size.y;
    var p = uv;
    if (aspect > 1.0) { p.y = (uv.y - 0.5) / aspect + 0.5; } else { p.x = (uv.x - 0.5) * aspect + 0.5; }
    let px = 1.0 / max(globals.size.x, globals.size.y);
    let frame = clamp(i32(floor(t * 30.0 + 0.5)), 0, 59);
    let e = envelope(p, frame, px);
    color = e.rgb + color * (1.0 - e.a);
    gpufx_write(id, vec4f(clamp(color, vec3f(0.0), vec3f(1.0)), 1.0));
}
