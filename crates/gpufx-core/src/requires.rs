//! `requires` of a manifest pass group: which devices a group runs on, and the device
//! facts ([`Target`]) a group is matched against.

use serde::Deserialize;

/// Values of `os`.
const OSES: &[&str] = &["windows", "linux", "macos", "web"];
/// Values of `backend`.
const BACKENDS: &[&str] = &["vulkan", "d3d12", "metal", "gl", "webgpu"];
/// Values of `vendor`.
const VENDORS: &[&str] = &["nvidia", "amd", "intel"];

/// Checks one feature on a target.
type FeatureCheck = fn(&Target) -> bool;
/// Values of `features` and how each is checked. Only features gpufx asks for on its
/// devices (see `GPU_FEATURES` in runtime.rs): others would never be enabled.
const FEATURES: &[(&str, FeatureCheck)] = &[
    ("shader-f16", |t| t.features.contains(wgpu::Features::SHADER_F16)),
    ("cooperative-matrix", |t| t.features.contains(wgpu::Features::EXPERIMENTAL_COOPERATIVE_MATRIX)),
    ("cooperative-matrix-f16", |t| t.coop_f16),
];

/// `"*"` or a non-empty list of values, any of which matches.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum Choice {
    #[default]
    Any,
    OneOf(Vec<String>),
}

impl<'de> Deserialize<'de> for Choice {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Raw {
            One(String),
            List(Vec<String>),
        }
        match Raw::deserialize(d)? {
            Raw::One(s) if s == "*" => Ok(Choice::Any),
            Raw::One(s) => Err(serde::de::Error::custom(format!("`{s}`: write \"*\" or a list such as [\"{s}\"]"))),
            Raw::List(l) => Ok(Choice::OneOf(l)),
        }
    }
}

impl Choice {
    fn validate(&self, key: &str, known: &[&str]) -> Result<(), String> {
        let Choice::OneOf(list) = self else { return Ok(()) };
        if list.is_empty() {
            return Err(format!("requires `{key}`: an empty list matches nothing (use \"*\" for any)"));
        }
        for v in list {
            if v == "*" {
                return Err(format!("requires `{key}`: \"*\" stands alone, not inside a list"));
            }
            if !known.contains(&v.as_str()) {
                return Err(format!("requires `{key}`: unknown value `{v}` (known: {})", known.join(", ")));
            }
        }
        Ok(())
    }

    fn allows(&self, value: Option<&str>) -> bool {
        match self {
            Choice::Any => true,
            Choice::OneOf(list) => value.is_some_and(|v| list.iter().any(|x| x == v)),
        }
    }

    fn reason(&self, key: &str) -> String {
        match self {
            Choice::Any => String::new(),
            Choice::OneOf(list) => format!("needs {key} {}", list.join(" or ")),
        }
    }
}

/// The device conditions of a pass group. Omitted keys match anything.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Requires {
    #[serde(default)]
    pub os: Choice,
    #[serde(default)]
    pub backend: Choice,
    #[serde(default)]
    pub vendor: Choice,
    /// Device features, all of them needed.
    #[serde(default)]
    pub features: Vec<String>,
}

impl Requires {
    pub(crate) fn validate(&self) -> Result<(), String> {
        self.os.validate("os", OSES)?;
        self.backend.validate("backend", BACKENDS)?;
        self.vendor.validate("vendor", VENDORS)?;
        for f in &self.features {
            if !FEATURES.iter().any(|(n, _)| n == f) {
                let known: Vec<&str> = FEATURES.iter().map(|(n, _)| *n).collect();
                return Err(format!("requires `features`: unknown feature `{f}` (known: {})", known.join(", ")));
            }
        }
        Ok(())
    }

    /// Why `target` cannot run this group, `None` when it can. A noop target (see
    /// [`Target::is_noop`]) is only checked against `os`.
    pub fn rejects(&self, target: &Target) -> Option<String> {
        let mut why = Vec::new();
        if !self.os.allows(Some(target.os)) {
            why.push(self.os.reason("os"));
        }
        if !target.is_noop {
            if !self.backend.allows(target.backend_name()) {
                why.push(self.backend.reason("backend"));
            }
            if !self.vendor.allows(target.vendor_name()) {
                why.push(self.vendor.reason("vendor"));
            }
            for f in &self.features {
                let check = FEATURES.iter().find(|(n, _)| n == f).map(|(_, c)| c);
                if !check.is_some_and(|c| c(target)) {
                    why.push(format!("needs feature {f}"));
                }
            }
        }
        (!why.is_empty()).then(|| why.join("; "))
    }

    /// The `features` of the group that `target` lacks, whatever the target is (a noop
    /// target included, unlike [`Requires::rejects`]).
    pub fn features_missing(&self, target: &Target) -> Vec<&str> {
        let has = |f: &str| FEATURES.iter().find(|(n, _)| *n == f).is_some_and(|(_, c)| c(target));
        self.features.iter().map(String::as_str).filter(|f| !has(f)).collect()
    }

    /// The group may run on D3D12 on Windows, whatever the vendor and features (what
    /// `gpufx pack --precompile` compiles).
    pub fn allows_d3d12(&self) -> bool {
        self.os.allows(Some("windows")) && self.backend.allows(Some("d3d12"))
    }

    /// e.g. `backend d3d12, features shader-f16`, or `*` when it matches anything.
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        for (key, c) in [("os", &self.os), ("backend", &self.backend), ("vendor", &self.vendor)] {
            if let Choice::OneOf(l) = c {
                parts.push(format!("{key} {}", l.join("|")));
            }
        }
        if !self.features.is_empty() {
            parts.push(format!("features {}", self.features.join("+")));
        }
        if parts.is_empty() {
            "*".into()
        } else {
            parts.join(", ")
        }
    }
}

/// What a group's `requires` are matched against: the OS and the device.
#[derive(Debug, Clone)]
pub struct Target {
    /// One of `windows`, `linux`, `macos`, `web`, or another name for other systems.
    pub os: &'static str,
    pub backend: wgpu::Backend,
    /// PCI vendor id, 0 when unknown.
    pub vendor: u32,
    /// Adapter name.
    pub name: String,
    /// Features enabled on the device.
    pub features: wgpu::Features,
    /// See [`crate::GpuContext::has_coop_f16`].
    pub coop_f16: bool,
    /// wgpu's noop device ([`crate::GpuContext::noop`]): only the OS is known.
    pub is_noop: bool,
}

impl Target {
    /// The OS this code runs on.
    pub fn current_os() -> &'static str {
        if cfg!(target_arch = "wasm32") {
            "web"
        } else if cfg!(windows) {
            "windows"
        } else if cfg!(target_os = "macos") {
            "macos"
        } else if cfg!(target_os = "linux") {
            "linux"
        } else {
            std::env::consts::OS
        }
    }

    pub fn backend_name(&self) -> Option<&'static str> {
        Some(match self.backend {
            wgpu::Backend::Vulkan => "vulkan",
            wgpu::Backend::Dx12 => "d3d12",
            wgpu::Backend::Metal => "metal",
            wgpu::Backend::Gl => "gl",
            wgpu::Backend::BrowserWebGpu => "webgpu",
            _ => return None,
        })
    }

    /// From the PCI vendor id, else from the adapter name.
    pub fn vendor_name(&self) -> Option<&'static str> {
        match self.vendor {
            0x10DE => return Some("nvidia"),
            0x1002 | 0x1022 => return Some("amd"),
            0x8086 => return Some("intel"),
            0 => {}
            _ => return None,
        }
        let name = self.name.to_ascii_lowercase();
        if name.contains("nvidia") || name.contains("geforce") {
            Some("nvidia")
        } else if name.contains("amd") || name.contains("radeon") {
            Some("amd")
        } else if name.contains("intel") {
            Some("intel")
        } else {
            None
        }
    }

    /// e.g. `Apple M2, metal`.
    pub fn describe(&self) -> String {
        let backend = self.backend_name().map_or_else(|| format!("{:?}", self.backend).to_ascii_lowercase(), String::from);
        format!("{}, {backend}", self.name)
    }
}
