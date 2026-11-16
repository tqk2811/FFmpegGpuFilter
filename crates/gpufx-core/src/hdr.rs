//! HDR (PQ, HLG) and wide gamut (BT.2020) input frames converted to the SDR BT.709 that
//! effects work in. The input pass (convert_in.wgsl, `to_sdr`) does this on the GPU; the
//! functions here are the same maths on the CPU, the reference the tests check it against.
//!
//! The choice, for frames whose transfer is PQ or HLG:
//!
//! 1. Linearize to display light in cd/m2: the PQ EOTF (SMPTE ST 2084), or for HLG the inverse
//!    OETF followed by the OOTF of BT.2100 for a [`HLG_PEAK`] display (system gamma 1.2).
//! 2. Tone map with the EETF of BT.2390, in the PQ domain, from the content peak (metadata
//!    clamped to [`MIN_PEAK`]..[`MAX_PEAK`], else [`DEFAULT_PQ_PEAK`]; [`HLG_PEAK`] for HLG)
//!    down to [`SDR_WHITE`], the reference white of BT.2408. The curve runs on one intensity
//!    per pixel, [`MAX_RGB_WEIGHT`] of max(R, G, B) blended with the BT.2020 luminance (the
//!    max-RGB approach of BT.2446 method C and libplacebo), and the RGB ratios are scaled by
//!    the same factor, so hues do not shift as they would with a per channel curve. Luminance
//!    alone would leave bright saturated colours (a blue or red highlight has a low luminance
//!    but a channel many times above white) nearly untouched, and step 4 would then pull them
//!    to grey; for greys max(R, G, B) equals the luminance, so they map as with luminance alone.
//! 3. Divide by [`SDR_WHITE`] and convert the gamut BT.2020 -> BT.709 with the standard
//!    3x3 matrix of BT.2087, in linear light. The content peak lands on SDR 1.0; levels at
//!    the knee and above are compressed, so the reference white itself (203 cd/m2) comes out
//!    below 1.0, about 0.90 after step 5 for a 1000 cd/m2 peak.
//! 4. Bring what lies outside [0, 1] back by desaturating towards the pixel's luminance just
//!    enough to fit (a soft clip that keeps the hue and the luminance), then clamp.
//! 5. Re-encode with the inverse of the BT.1886 EOTF (gamma 2.4): the result is display
//!    referred, as SDR BT.709 video is when shown, which is what the rest of the pipeline
//!    and the BT.709 encoder treat effect RGB as.
//!
//! Frames with SDR transfer but BT.2020 primaries (10-bit SDR) only get steps 3 to 5, after
//! linearizing with the BT.1886 EOTF.

use crate::frame::{Primaries, Transfer};

/// Reference white of SDR in HDR content (BT.2408), in cd/m2: the target peak of the tone
/// map, which becomes SDR 1.0. The reference white of the content, below the content peak,
/// lands lower (see step 3 of the module documentation).
pub const SDR_WHITE: f64 = 203.0;
/// Peak luminance assumed for PQ content without metadata, in cd/m2.
pub const DEFAULT_PQ_PEAK: f64 = 1000.0;
/// Range the content peak of the metadata is clamped to, in cd/m2. MaxCLL and mastering
/// values below 400 are almost always wrong (unset fields, a few nits) for content tagged PQ,
/// and nothing goes above the 10000 of the PQ curve.
pub const MIN_PEAK: f64 = 400.0;
pub const MAX_PEAK: f64 = 10000.0;
/// Share of max(R, G, B) in the intensity the tone map runs on, the rest being the luminance.
pub const MAX_RGB_WEIGHT: f64 = 0.75;
/// Nominal peak of the HLG reference display, in cd/m2.
pub const HLG_PEAK: f64 = 1000.0;
/// Exponent of the BT.1886 EOTF.
pub const SDR_GAMMA: f64 = 2.4;

/// BT.2020 -> BT.709 in linear light (BT.2087), rows give R, G, B.
pub const BT2020_TO_BT709: [[f64; 3]; 3] = [
    [1.660491, -0.587641, -0.072850],
    [-0.124550, 1.132900, -0.008349],
    [-0.018151, -0.100579, 1.118730],
];
/// Luma weights of BT.2020 and BT.709.
pub const BT2020_LUMA: [f64; 3] = [0.2627, 0.6780, 0.0593];
pub const BT709_LUMA: [f64; 3] = [0.2126, 0.7152, 0.0722];

const PQ_M1: f64 = 2610.0 / 16384.0;
const PQ_M2: f64 = 2523.0 / 4096.0 * 128.0;
const PQ_C1: f64 = 3424.0 / 4096.0;
const PQ_C2: f64 = 2413.0 / 4096.0 * 32.0;
const PQ_C3: f64 = 2392.0 / 4096.0 * 32.0;

const HLG_A: f64 = 0.178_832_77;
const HLG_B: f64 = 0.284_668_92;
const HLG_C: f64 = 0.559_910_73;

/// PQ EOTF: a signal in [0, 1] to cd/m2 (0 to 10000).
pub fn pq_eotf(e: f64) -> f64 {
    let p = e.clamp(0.0, 1.0).powf(1.0 / PQ_M2);
    let num = (p - PQ_C1).max(0.0);
    10000.0 * (num / (PQ_C2 - PQ_C3 * p)).powf(1.0 / PQ_M1)
}

/// Inverse PQ EOTF: cd/m2 to a signal in [0, 1].
pub fn pq_inverse_eotf(nits: f64) -> f64 {
    let y = (nits / 10000.0).clamp(0.0, 1.0).powf(PQ_M1);
    ((PQ_C1 + PQ_C2 * y) / (1.0 + PQ_C3 * y)).powf(PQ_M2)
}

/// HLG inverse OETF: a signal in [0, 1] to normalized scene light in [0, 1].
pub fn hlg_inverse_oetf(e: f64) -> f64 {
    let e = e.clamp(0.0, 1.0);
    if e <= 0.5 {
        e * e / 3.0
    } else {
        (((e - HLG_C) / HLG_A).exp() + HLG_B) / 12.0
    }
}

/// OOTF of BT.2100 for HLG on a [`HLG_PEAK`] display: normalized scene light (BT.2020) to
/// display light in cd/m2, Fd = Lw * Ys^(gamma - 1) * E with gamma 1.2.
pub fn hlg_ootf(scene: [f64; 3]) -> [f64; 3] {
    let ys = dot(scene, BT2020_LUMA);
    let gain = if ys > 0.0 { HLG_PEAK * ys.powf(0.2) } else { 0.0 };
    scene.map(|c| c * gain)
}

/// BT.2390 EETF on a luminance in cd/m2: maps `source_peak` to `target_peak`, leaves the
/// levels below the knee unchanged (black is 0 on both sides).
pub fn eetf(nits: f64, source_peak: f64, target_peak: f64) -> f64 {
    if source_peak <= target_peak {
        return nits.min(source_peak);
    }
    let peak = pq_inverse_eotf(source_peak);
    let e1 = pq_inverse_eotf(nits) / peak;
    let max_lum = pq_inverse_eotf(target_peak) / peak;
    let ks = 1.5 * max_lum - 0.5;
    let e2 = if e1 < ks {
        e1
    } else {
        let t = ((e1 - ks) / (1.0 - ks)).min(1.0);
        let (t2, t3) = (t * t, t * t * t);
        (2.0 * t3 - 3.0 * t2 + 1.0) * ks + (t3 - 2.0 * t2 + t) * (1.0 - ks) + (-2.0 * t3 + 3.0 * t2) * max_lum
    };
    pq_eotf(e2 * peak)
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

/// Step 4: desaturates `rgb` towards its BT.709 luminance just enough to fit [0, 1].
pub fn fit_gamut(rgb: [f64; 3]) -> [f64; 3] {
    let y = dot(rgb, BT709_LUMA).clamp(0.0, 1.0);
    let max = rgb[0].max(rgb[1]).max(rgb[2]);
    let min = rgb[0].min(rgb[1]).min(rgb[2]);
    let mut s: f64 = 1.0;
    if max > 1.0 {
        s = s.min((1.0 - y) / (max - y));
    }
    if min < 0.0 {
        s = s.min(y / (y - min));
    }
    rgb.map(|c| (y + (c - y) * s).clamp(0.0, 1.0))
}

/// The intensity the tone map curve runs on for linear BT.2020 `rgb` (step 2): max(R, G, B)
/// blended with the luminance by [`MAX_RGB_WEIGHT`].
pub fn tone_map_intensity(rgb: [f64; 3]) -> f64 {
    let max = rgb[0].max(rgb[1]).max(rgb[2]);
    MAX_RGB_WEIGHT * max + (1.0 - MAX_RGB_WEIGHT) * dot(rgb, BT2020_LUMA)
}

/// The peak a frame is tone mapped from, in cd/m2.
pub fn source_peak(transfer: Transfer, peak_nits: u32) -> f64 {
    match transfer {
        Transfer::Hlg => HLG_PEAK,
        _ if peak_nits > 0 => f64::from(peak_nits).clamp(MIN_PEAK, MAX_PEAK),
        _ => DEFAULT_PQ_PEAK,
    }
}

/// Non-linear RGB of `primaries` and `transfer`, in [0, 1], to SDR BT.709 RGB as effects see it.
pub fn to_sdr(rgb: [f64; 3], transfer: Transfer, primaries: Primaries, peak_nits: u32) -> [f64; 3] {
    let linear = match transfer {
        Transfer::Sdr => rgb.map(|c| c.clamp(0.0, 1.0).powf(SDR_GAMMA)),
        Transfer::Pq | Transfer::Hlg => {
            let display = match transfer {
                Transfer::Pq => rgb.map(pq_eotf),
                _ => hlg_ootf(rgb.map(hlg_inverse_oetf)),
            };
            let intensity = tone_map_intensity(display);
            let mapped = eetf(intensity, source_peak(transfer, peak_nits), SDR_WHITE);
            let ratio = if intensity > 0.0 { mapped / intensity } else { 0.0 };
            display.map(|c| c * ratio / SDR_WHITE)
        }
    };
    let bt709 = match primaries {
        Primaries::Bt709 => linear,
        Primaries::Bt2020 => BT2020_TO_BT709.map(|row| dot(row, linear)),
    };
    fit_gamut(bt709).map(|c| c.powf(1.0 / SDR_GAMMA))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(a: f64, b: f64, tolerance: f64) -> bool {
        (a - b).abs() <= tolerance
    }

    #[test]
    fn pq_matches_the_published_values() {
        assert!(close(pq_eotf(1.0), 10000.0, 1e-6));
        assert_eq!(pq_eotf(0.0), 0.0);
        // ST 2084: 100 cd/m2 is code 0.508, 1000 cd/m2 is 0.752.
        assert!(close(pq_inverse_eotf(100.0), 0.5081, 1e-3), "{}", pq_inverse_eotf(100.0));
        assert!(close(pq_inverse_eotf(1000.0), 0.7518, 1e-3), "{}", pq_inverse_eotf(1000.0));
        for nits in [0.1, 1.0, 50.0, 203.0, 4000.0] {
            assert!(close(pq_eotf(pq_inverse_eotf(nits)), nits, nits * 1e-9 + 1e-9), "{nits}");
        }
    }

    #[test]
    fn hlg_inverse_oetf_is_continuous_and_reaches_one() {
        assert!(close(hlg_inverse_oetf(0.5), 1.0 / 12.0, 1e-12));
        assert!(close(hlg_inverse_oetf(0.5 + 1e-9), 1.0 / 12.0, 1e-6), "the two pieces meet");
        assert!(close(hlg_inverse_oetf(1.0), 1.0, 1e-6), "{}", hlg_inverse_oetf(1.0));
        assert_eq!(hlg_inverse_oetf(0.0), 0.0);
    }

    #[test]
    fn the_eetf_keeps_the_lows_and_lands_the_peak_on_the_target() {
        assert!(close(eetf(1000.0, 1000.0, SDR_WHITE), SDR_WHITE, 1e-6));
        assert!(close(eetf(10.0, 1000.0, SDR_WHITE), 10.0, 1e-9), "below the knee nothing changes");
        let mut last = 0.0;
        for i in 1..=100 {
            let out = eetf(f64::from(i) * 10.0, 1000.0, SDR_WHITE);
            assert!(out >= last && out <= SDR_WHITE + 1e-9, "monotonic and bounded at {i}");
            last = out;
        }
        assert_eq!(eetf(150.0, 100.0, SDR_WHITE), 100.0, "content darker than the target is left alone");
    }

    #[test]
    fn hdr_white_and_grey_map_to_sensible_sdr_levels() {
        // PQ peak white of a 1000 cd/m2 grade becomes SDR white.
        let white = to_sdr([0.7518; 3], Transfer::Pq, Primaries::Bt2020, 1000);
        assert!(white.iter().all(|&c| close(c, 1.0, 2e-3)), "{white:?}");
        // HLG 75 % is the reference white of BT.2408 (203 cd/m2): compressed by the knee, below 1.
        let hlg = to_sdr([0.75; 3], Transfer::Hlg, Primaries::Bt2020, 0);
        assert!(hlg[0] > 0.85 && hlg[0] < 1.0, "{hlg:?}");
        assert_eq!(to_sdr([0.0; 3], Transfer::Pq, Primaries::Bt2020, 0), [0.0; 3]);
    }

    #[test]
    fn sdr_bt709_passes_through_and_bt2020_primaries_are_converted() {
        let rgb = [0.2, 0.5, 0.8];
        let same = to_sdr(rgb, Transfer::Sdr, Primaries::Bt709, 0);
        assert!(same.iter().zip(rgb).all(|(a, b)| close(*a, b, 1e-9)), "{same:?}");
        // Grey stays grey across the gamut conversion (the matrix rows sum to 1).
        let grey = to_sdr([0.5; 3], Transfer::Sdr, Primaries::Bt2020, 0);
        assert!(grey.iter().all(|&c| close(c, 0.5, 1e-4)), "{grey:?}");
        // BT.2020 pure green lies outside BT.709: it stays the most green, fitted into range.
        let green = to_sdr([0.0, 1.0, 0.0], Transfer::Sdr, Primaries::Bt2020, 0);
        assert!(green[1] > green[0] && green[1] > green[2] && green.iter().all(|c| (0.0..=1.0).contains(c)), "{green:?}");
    }

    #[test]
    fn greys_follow_their_luminance_and_the_metadata_peak_is_clamped() {
        // For a grey max(R, G, B) is the luminance: the blend changes nothing there.
        assert!(close(tone_map_intensity([150.0; 3]), 150.0, 1e-9));
        assert!(tone_map_intensity([0.0, 0.0, 100.0]) > 70.0, "a saturated blue counts by its channel");
        assert_eq!(source_peak(Transfer::Pq, 0), DEFAULT_PQ_PEAK);
        assert_eq!(source_peak(Transfer::Pq, 5), MIN_PEAK, "a bogus MaxCLL of a few nits");
        assert_eq!(source_peak(Transfer::Pq, 4000), 4000.0);
        assert_eq!(source_peak(Transfer::Pq, 50000), MAX_PEAK);
        assert_eq!(source_peak(Transfer::Hlg, 4000), HLG_PEAK);
    }

    #[test]
    fn fitting_keeps_luminance_and_range() {
        let fitted = fit_gamut([1.4, 0.6, -0.1]);
        assert!(fitted.iter().all(|c| (0.0..=1.0).contains(c)), "{fitted:?}");
        assert!(close(dot(fitted, BT709_LUMA), dot([1.4, 0.6, -0.1], BT709_LUMA), 1e-9));
        assert_eq!(fit_gamut([0.3, 0.4, 0.5]), [0.3, 0.4, 0.5]);
    }
}
