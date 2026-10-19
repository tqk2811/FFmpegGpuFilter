//! Converts neural network models to `gpufx-nn` packages (see docs/NN_MODEL_FORMAT.md).

pub mod convert;
pub mod model;
pub mod ncnn;
pub mod package;

pub use convert::{convert_ncnn, Converted};
pub use package::Package;

#[derive(Debug)]
pub struct Error(pub String);

pub type Result<T> = std::result::Result<T, Error>;

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error(e.to_string())
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error(e.to_string())
    }
}

impl From<zip::result::ZipError> for Error {
    fn from(e: zip::result::ZipError) -> Self {
        Error(e.to_string())
    }
}

pub(crate) fn fail<T>(msg: impl Into<String>) -> Result<T> {
    Err(Error(msg.into()))
}
