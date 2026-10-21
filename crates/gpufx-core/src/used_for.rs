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

/// The error for `files` missing `what` (the file the opener reads first): says what kind of package they are
/// and which filter to use when they are a known kind.
pub(crate) fn wrong_kind(files: &HashMap<String, Vec<u8>>, what: &str) -> Error {
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
    let kind = if let Some(m) = files.get("manifest.json") {
        format!("it is a gpufx effect package{}", filters(used_for(m)))
    } else if let Some(m) = model {
        format!("it is a gpufx-nn model package{}", filters(used_for(m)))
    } else if files.contains_key("package.json") {
        "it is a gpufx-nn model bundle".to_string()
    } else {
        return Error::Package(format!("missing {what}"));
    };
    Error::Package(format!("missing {what}: {kind}"))
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
