//! The FFmpeg filters a package is for: `used_for` in an effect `manifest.json` and a gpufx-nn `model.json`.
//! Required in both; each filter that opens a package checks its own name is listed.

use std::collections::HashMap;

use crate::Error;

/// The `gpufx` filter: effect packages (`manifest.json`).
pub const GPUFX: &str = "gpufx";
/// The `gpufx_ai_upscale` filter: gpufx-nn `super_resolution` models.
pub const AI_UPSCALE: &str = "gpufx_ai_upscale";
/// The `gpufx_ai_framerate` filter: gpufx-nn `frame_interp` models.
pub const AI_FRAMERATE: &str = "gpufx_ai_framerate";
/// The io.json `kind` each AI filter runs. Same table as `gpufx-nnconv` (`package::FILTERS`), which does not
/// depend on this crate.
const KINDS: &[(&str, &str)] = &[(AI_UPSCALE, "super_resolution"), (AI_FRAMERATE, "frame_interp")];
/// Every filter name `used_for` may list.
pub const FILTERS: &[&str] = &[GPUFX, AI_UPSCALE, AI_FRAMERATE];

/// Checks a `used_for` list: not empty, known filter names, no duplicates.
pub(crate) fn validate(list: &[String]) -> Result<(), String> {
    if list.is_empty() {
        return Err(format!("`used_for` is empty: list the filters the package is for ({})", FILTERS.join(", ")));
    }
    for (i, f) in list.iter().enumerate() {
        if !FILTERS.contains(&f.as_str()) {
            return Err(format!("`used_for` names unknown filter `{f}` (known: {})", FILTERS.join(", ")));
        }
        if list[..i].contains(f) {
            return Err(format!("`used_for` lists `{f}` twice"));
        }
    }
    Ok(())
}

/// Fails unless the package `name` is for `filter`.
pub fn check(name: &str, used_for: &[String], filter: &str) -> Result<(), Error> {
    if used_for.iter().any(|f| f == filter) {
        return Ok(());
    }
    let name = if name.is_empty() { "(unnamed)" } else { name };
    Err(Error::Package(format!("package `{name}` is for {}, not {filter}", used_for.join(", "))))
}

/// Fails when the io.json `kind` of the package `name` is not the one `filter` runs: its `used_for` lists the
/// filter, but the model is for another (`gpufx-nnconv` refuses to write such a package). No `kind` passes.
pub fn check_kind(name: &str, io: &serde_json::Value, filter: &str) -> Result<(), Error> {
    let kind = io.get("kind").and_then(serde_json::Value::as_str);
    let (Some(kind), Some((_, runs))) = (kind, KINDS.iter().find(|(f, _)| *f == filter)) else {
        return Ok(());
    };
    if kind == *runs {
        return Ok(());
    }
    let name = if name.is_empty() { "(unnamed)" } else { name };
    Err(Error::Package(format!(
        "package `{name}`: used_for/kind mismatch: it lists {filter}, which runs {runs} models, but io.json has kind \"{kind}\""
    )))
}

/// The error for `files` missing `what` (the file the opener reads first): says what kind of package they are
/// and which filter to use when they are a known kind.
pub(crate) fn wrong_kind(files: &HashMap<String, Vec<u8>>, what: &str) -> Error {
    match describe(files) {
        Some(kind) => Error::Package(format!("missing {what}: {kind}")),
        None => Error::Package(format!("missing {what}")),
    }
}

/// What kind of package `files` are and which filter takes them ("it is a ..."), when a known kind.
pub(crate) fn describe(files: &HashMap<String, Vec<u8>>) -> Option<String> {
    #[derive(serde::Deserialize)]
    struct UsedFor {
        #[serde(default)]
        used_for: Vec<String>,
    }
    let used_for = |b: &Vec<u8>| serde_json::from_slice::<UsedFor>(b).map(|u| u.used_for).unwrap_or_default();
    let filters = |l: Vec<String>| if l.is_empty() { String::new() } else { format!(", use it with the {} filter", l.join(" or ")) };
    let model = files.get("model.json").or_else(|| {
        // a bundle: the variants share their filters, ask the first one
        let v: serde_json::Value = serde_json::from_slice(files.get("package.json")?).ok()?;
        files.get(&format!("{}/model.json", v["variants"][0]["dir"].as_str()?))
    });
    if let Some(m) = files.get("manifest.json") {
        Some(format!("it is a gpufx effect package{}", filters(used_for(m))))
    } else if let Some(m) = model {
        Some(format!("it is a gpufx-nn model package{}", filters(used_for(m))))
    } else if files.contains_key("package.json") {
        Some("it is a gpufx-nn model bundle".to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn validate_rejects_empty_unknown_and_duplicate() {
        assert!(validate(&list(&[GPUFX])).is_ok());
        assert!(validate(&list(&[AI_UPSCALE, AI_FRAMERATE])).is_ok());
        assert!(validate(&[]).unwrap_err().contains("empty"));
        assert!(validate(&list(&["gpufx_blur"])).unwrap_err().contains("unknown filter `gpufx_blur`"));
        assert!(validate(&list(&[GPUFX, GPUFX])).unwrap_err().contains("twice"));
    }

    #[test]
    fn check_names_the_filters_of_the_package() {
        assert!(check("a", &list(&[AI_UPSCALE, AI_FRAMERATE]), AI_FRAMERATE).is_ok());
        let e = check("realesr-x4", &list(&[AI_UPSCALE]), AI_FRAMERATE).unwrap_err().to_string();
        assert_eq!(e, "package: package `realesr-x4` is for gpufx_ai_upscale, not gpufx_ai_framerate");
    }

    #[test]
    fn check_kind_reports_a_used_for_kind_mismatch() {
        let io = |k: &str| serde_json::json!({ "kind": k });
        assert!(check_kind("a", &io("super_resolution"), AI_UPSCALE).is_ok());
        assert!(check_kind("a", &io("frame_interp"), AI_FRAMERATE).is_ok());
        assert!(check_kind("a", &serde_json::Value::Null, AI_UPSCALE).is_ok());
        let e = check_kind("m", &io("frame_interp"), AI_UPSCALE).unwrap_err().to_string();
        assert_eq!(
            e,
            "package: package `m`: used_for/kind mismatch: it lists gpufx_ai_upscale, which runs super_resolution models, but io.json has kind \"frame_interp\""
        );
    }

    #[test]
    fn wrong_kind_says_what_the_package_is() {
        let files = |n: &[(&str, &str)]| n.iter().map(|(k, v)| (k.to_string(), v.as_bytes().to_vec())).collect::<HashMap<_, _>>();
        let fx = files(&[("manifest.json", r#"{"used_for":["gpufx"]}"#)]);
        let e = wrong_kind(&fx, "model.json").to_string();
        assert!(e.contains("missing model.json: it is a gpufx effect package, use it with the gpufx filter"), "{e}");
        let model = files(&[("model.json", r#"{"used_for":["gpufx_ai_framerate"]}"#)]);
        let e = wrong_kind(&model, "manifest.json").to_string();
        assert!(e.contains("it is a gpufx-nn model package, use it with the gpufx_ai_framerate filter"), "{e}");
        let bundle =
            files(&[("package.json", r#"{"variants":[{"dir":"x2"}]}"#), ("x2/model.json", r#"{"used_for":["gpufx_ai_upscale"]}"#)]);
        let e = wrong_kind(&bundle, "manifest.json").to_string();
        assert!(e.contains("use it with the gpufx_ai_upscale filter"), "{e}");
        assert_eq!(wrong_kind(&files(&[]), "manifest.json").to_string(), "package: missing manifest.json");
    }
}
