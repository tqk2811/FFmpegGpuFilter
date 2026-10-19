//! Reader of the ncnn `.param` text format.

use std::collections::HashMap;

use crate::{fail, Error, Result};

const MAGIC: &str = "7767517";

/// Layer parameters: `key=value` and, for negative keys, `key=n,v1,..,vn`.
#[derive(Debug, Default)]
pub struct Params {
    values: HashMap<i32, String>,
    arrays: HashMap<i32, Vec<String>>,
}

impl Params {
    pub fn has(&self, key: i32) -> bool {
        self.values.contains_key(&key) || self.arrays.contains_key(&key)
    }

    pub fn int(&self, key: i32, default: i64) -> Result<i64> {
        let Some(v) = self.values.get(&key) else { return Ok(default) };
        parse_int(v).ok_or_else(|| Error(format!("key {key}: '{v}' is not an integer")))
    }

    pub fn float(&self, key: i32, default: f32) -> Result<f32> {
        let Some(v) = self.values.get(&key) else { return Ok(default) };
        v.parse().map_err(|_| Error(format!("key {key}: '{v}' is not a number")))
    }

    pub fn int_array(&self, key: i32) -> Result<Option<Vec<i64>>> {
        let Some(a) = self.arrays.get(&key) else { return Ok(None) };
        a.iter()
            .map(|v| parse_int(v).ok_or_else(|| Error(format!("key {key}: '{v}' is not an integer"))))
            .collect::<Result<Vec<_>>>()
            .map(Some)
    }

    pub fn float_array(&self, key: i32) -> Result<Option<Vec<f32>>> {
        let Some(a) = self.arrays.get(&key) else { return Ok(None) };
        a.iter().map(|v| v.parse().map_err(|_| Error(format!("key {key}: '{v}' is not a number")))).collect::<Result<Vec<_>>>().map(Some)
    }

    /// Fails on a key the converter does not understand: ignoring it could silently change the model.
    pub fn expect_only(&self, allowed: &[i32]) -> Result<()> {
        let mut unknown: Vec<i32> = self.values.keys().chain(self.arrays.keys()).copied().filter(|k| !allowed.contains(k)).collect();
        unknown.sort_unstable();
        match unknown.first() {
            Some(k) => fail(format!("unsupported parameter {k}")),
            None => Ok(()),
        }
    }
}

fn parse_int(v: &str) -> Option<i64> {
    if let Ok(i) = v.parse::<i64>() {
        return Some(i);
    }
    let f = v.parse::<f64>().ok()?;
    (f.fract() == 0.0 && f.abs() < 9e15).then_some(f as i64)
}

#[derive(Debug)]
pub struct Layer {
    pub ty: String,
    pub name: String,
    pub inputs: Vec<String>,
    pub outputs: Vec<String>,
    pub params: Params,
}

impl Layer {
    pub fn err(&self, msg: impl std::fmt::Display) -> Error {
        Error(format!("layer '{}' ({}): {msg}", self.name, self.ty))
    }
}

pub fn parse_param(text: &str) -> Result<Vec<Layer>> {
    let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
    let magic = lines.next().unwrap_or("");
    if magic.trim_start_matches('\u{feff}') != MAGIC {
        return fail("not an ncnn param file (bad magic)");
    }
    let counts = lines.next().ok_or_else(|| Error("missing layer count line".into()))?;
    let layer_count: usize =
        counts.split_whitespace().next().and_then(|v| v.parse().ok()).ok_or_else(|| Error(format!("bad layer count line '{counts}'")))?;
    let mut layers = Vec::with_capacity(layer_count);
    for line in lines {
        layers.push(parse_layer(line).map_err(|e| Error(format!("param line '{line}': {e}")))?);
    }
    if layers.len() != layer_count {
        return fail(format!("header declares {layer_count} layers but the file has {}", layers.len()));
    }
    Ok(layers)
}

fn parse_layer(line: &str) -> Result<Layer> {
    let mut t = line.split_whitespace();
    let mut next = |what: &str| t.next().ok_or_else(|| Error(format!("missing {what}")));
    let ty = next("layer type")?.to_string();
    let name = next("layer name")?.to_string();
    let nin: usize = next("input count")?.parse().map_err(|_| Error("bad input count".into()))?;
    let nout: usize = next("output count")?.parse().map_err(|_| Error("bad output count".into()))?;
    let inputs = (0..nin).map(|_| next("input blob").map(str::to_string)).collect::<Result<Vec<_>>>()?;
    let outputs = (0..nout).map(|_| next("output blob").map(str::to_string)).collect::<Result<Vec<_>>>()?;
    let mut params = Params::default();
    for kv in t {
        let (k, v) = kv.split_once('=').ok_or_else(|| Error(format!("bad parameter '{kv}'")))?;
        let key: i32 = k.parse().map_err(|_| Error(format!("bad parameter key '{k}'")))?;
        if key <= -23300 {
            let mut items = v.split(',');
            let n: usize = items.next().and_then(|c| c.parse().ok()).ok_or_else(|| Error(format!("bad array '{kv}'")))?;
            let items: Vec<String> = items.map(str::to_string).collect();
            if items.len() != n {
                return fail(format!("array '{kv}' declares {n} values but has {}", items.len()));
            }
            params.arrays.insert(key, items);
        } else {
            params.values.insert(key, v.to_string());
        }
    }
    Ok(Layer { ty, name, inputs, outputs, params })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_layers_and_arrays() {
        let text = "7767517\r\n2 2\r\nInput in0 0 1 in0\r\nConvolution c 1 1 in0 x 0=4 -23310=1,2.0e-01 5=1\r\n";
        let layers = parse_param(text).unwrap();
        assert_eq!(layers.len(), 2);
        assert_eq!(layers[1].inputs, ["in0"]);
        assert_eq!(layers[1].params.int(0, 0).unwrap(), 4);
        assert_eq!(layers[1].params.float_array(-23310).unwrap().unwrap(), [0.2]);
        assert!(layers[1].params.expect_only(&[0, 5]).is_err());
    }

    #[test]
    fn rejects_bad_files() {
        assert!(parse_param("1234\n0 0\n").is_err());
        assert!(parse_param("7767517\n2 1\nInput a 0 1 a\n").is_err());
        assert!(parse_param("7767517\n1 1\nCrop c 1 1 a b -23309=2,1\n").is_err());
    }
}
