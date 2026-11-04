use arrow_array::{
    Array, ArrayRef, BooleanArray, Float32Array, Float64Array, Int32Array, Int64Array,
    LargeStringArray, StringArray, StringViewArray, UInt16Array, UInt32Array, UInt64Array,
    UInt8Array,
};
use byteorder::{LittleEndian, ReadBytesExt};
use bytes::Bytes;
use vortex_array::IntoCanonical;
use vortex_ipc::messages::reader::{ArrayMessageReader, DTypeBufferReader};
use vortex_sampling_compressor::ALL_ENCODINGS_CONTEXT;

const ALIGNMENT: usize = 64;

#[derive(Clone, Copy)]
pub enum Compression {
    None,
    Zstd,
    Lz4,
}

#[derive(Clone, Copy)]
pub enum Requested {
    Primitive,
    List,
}

pub enum Values {
    Bytes(Vec<u8>),
    Utf8(Vec<String>),
}

pub struct OwnedCol {
    pub kind: &'static str,
    pub rows: usize,
    pub values: Values,
    pub validity: Option<Vec<u8>>,
}

pub fn decode_owned(
    bytes: Vec<u8>,
    compression: Compression,
    requested: Requested,
) -> Result<OwnedCol, String> {
    let plain = decompress(compression, bytes)?;
    match requested {
        Requested::List => decode_list(Bytes::from(plain)),
        Requested::Primitive => {
            let mut payload = Bytes::from(plain);
            let array = to_arrow(vortex_deser(&mut payload)?)?;
            export_array(array)
        }
    }
}

fn decompress(compression: Compression, bytes: Vec<u8>) -> Result<Vec<u8>, String> {
    match compression {
        Compression::None => Ok(bytes),
        Compression::Zstd => zstd::stream::decode_all(bytes.as_slice()).map_err(show),
        Compression::Lz4 => lz4_flex::decompress_size_prepended(bytes.as_slice()).map_err(show),
    }
}

fn decode_list(mut payload: Bytes) -> Result<OwnedCol, String> {
    let validity = to_arrow(vortex_deser(&mut payload)?)?;
    let offsets = to_arrow(vortex_deser(&mut payload)?)?;
    let flags = validity
        .as_any()
        .downcast_ref::<BooleanArray>()
        .ok_or_else(|| "list validity is not a boolean array".to_string())?;
    let rows = flags.len();
    let (kind, values) = offset_bytes(offsets.as_ref(), rows)?;
    let validity_bytes = Some((0..rows).map(|i| u8::from(flags.value(i))).collect());
    Ok(OwnedCol {
        kind,
        rows,
        values: Values::Bytes(values),
        validity: blank_if_full(validity_bytes, rows),
    })
}

fn vortex_deser(payload: &mut Bytes) -> Result<vortex_array::ArrayData, String> {
    if payload.len() < 4 {
        return Err("truncated encunit".to_string());
    }
    let metadata_size = payload
        .split_to(4)
        .as_ref()
        .read_u32::<LittleEndian>()
        .map_err(show)? as usize;
    if payload.len() < metadata_size {
        return Err("truncated dtype".to_string());
    }
    let mut dtype_bytes = payload.split_to(metadata_size);
    let dtype = read_dtype(&mut dtype_bytes)?;
    let pad = padding(metadata_size + 4);
    if payload.len() < pad {
        return Err("truncated alignment".to_string());
    }
    let _padding = payload.split_to(pad);
    let mut reader = ArrayMessageReader::new();
    let mut read_buf = Bytes::new();
    for _step in 0..8 {
        match reader.read(read_buf).map_err(show)? {
            Some(needed) => {
                if payload.len() < needed {
                    return Err("truncated array body".to_string());
                }
                read_buf = payload.split_to(needed);
            }
            None => {
                return reader
                    .into_array(ALL_ENCODINGS_CONTEXT.clone(), dtype)
                    .map_err(show);
            }
        }
    }
    Err("vortex message did not finish".to_string())
}

fn read_dtype(dtype_bytes: &mut Bytes) -> Result<vortex_dtype::DType, String> {
    let mut reader = DTypeBufferReader::new();
    let mut read_buf = Bytes::new();
    for _step in 0..8 {
        match reader.read(read_buf).map_err(show)? {
            Some(needed) => {
                if dtype_bytes.len() < needed {
                    return Err("truncated dtype body".to_string());
                }
                read_buf = dtype_bytes.split_to(needed);
            }
            None => return Ok(reader.into_dtype()),
        }
    }
    Err("dtype message did not finish".to_string())
}

fn padding(size: usize) -> usize {
    size.next_multiple_of(ALIGNMENT) - size
}

fn to_arrow(array: vortex_array::ArrayData) -> Result<ArrayRef, String> {
    array
        .into_canonical()
        .map_err(show)?
        .into_arrow()
        .map_err(show)
}

fn export_array(array: ArrayRef) -> Result<OwnedCol, String> {
    let rows = array.len();
    let validity = validity_bytes(array.as_ref());
    if let Some(values) = array.as_any().downcast_ref::<Int64Array>() {
        return Ok(bin_col("i64", rows, le_bytes(values.values()), validity));
    }
    if let Some(values) = array.as_any().downcast_ref::<Int32Array>() {
        return Ok(bin_col("i32", rows, le_bytes(values.values()), validity));
    }
    if let Some(values) = array.as_any().downcast_ref::<UInt64Array>() {
        return Ok(bin_col("u64", rows, le_bytes(values.values()), validity));
    }
    if let Some(values) = array.as_any().downcast_ref::<UInt32Array>() {
        return Ok(bin_col("u32", rows, le_bytes(values.values()), validity));
    }
    if let Some(values) = array.as_any().downcast_ref::<UInt16Array>() {
        return Ok(bin_col("u16", rows, le_bytes(values.values()), validity));
    }
    if let Some(values) = array.as_any().downcast_ref::<UInt8Array>() {
        return Ok(bin_col("u8", rows, le_bytes(values.values()), validity));
    }
    if let Some(values) = array.as_any().downcast_ref::<Float64Array>() {
        return Ok(bin_col("f64", rows, le_bytes(values.values()), validity));
    }
    if let Some(values) = array.as_any().downcast_ref::<Float32Array>() {
        return Ok(bin_col("f32", rows, le_bytes(values.values()), validity));
    }
    if let Some(flags) = array.as_any().downcast_ref::<BooleanArray>() {
        let values = (0..rows).map(|i| u8::from(flags.value(i))).collect();
        return Ok(bin_col("bool", rows, values, validity));
    }
    if let Some(values) = strings(&array) {
        return Ok(OwnedCol {
            kind: "utf8",
            rows,
            values: Values::Utf8(values),
            validity,
        });
    }
    Err(format!("unsupported arrow type {}", array.data_type()))
}

fn le_bytes<T: LeBytes>(values: &[T]) -> Vec<u8> {
    let mut out = Vec::with_capacity(values.len() * T::WIDTH);
    for value in values {
        value.write_le(&mut out);
    }
    out
}

trait LeBytes {
    const WIDTH: usize;
    fn write_le(&self, out: &mut Vec<u8>);
}

macro_rules! le_bytes_for {
    ($ty:ty) => {
        impl LeBytes for $ty {
            const WIDTH: usize = std::mem::size_of::<$ty>();
            fn write_le(&self, out: &mut Vec<u8>) {
                out.extend_from_slice(&self.to_le_bytes());
            }
        }
    };
}

le_bytes_for!(i32);
le_bytes_for!(i64);
le_bytes_for!(u8);
le_bytes_for!(u16);
le_bytes_for!(u32);
le_bytes_for!(u64);
le_bytes_for!(f32);
le_bytes_for!(f64);

fn strings(array: &ArrayRef) -> Option<Vec<String>> {
    let rows = array.len();
    if let Some(values) = array.as_any().downcast_ref::<StringArray>() {
        return Some((0..rows).map(|i| string_at(values, i)).collect());
    }
    if let Some(values) = array.as_any().downcast_ref::<LargeStringArray>() {
        return Some((0..rows).map(|i| string_at(values, i)).collect());
    }
    if let Some(values) = array.as_any().downcast_ref::<StringViewArray>() {
        return Some((0..rows).map(|i| string_at(values, i)).collect());
    }
    None
}

fn string_at<T>(values: &T, index: usize) -> String
where
    T: Array,
{
    if values.is_valid(index) {
        utf8_text(values, index)
    } else {
        String::new()
    }
}

fn utf8_text<T: Array + ?Sized>(values: &T, index: usize) -> String {
    if let Some(values) = values.as_any().downcast_ref::<StringArray>() {
        return values.value(index).to_string();
    }
    if let Some(values) = values.as_any().downcast_ref::<LargeStringArray>() {
        return values.value(index).to_string();
    }
    if let Some(values) = values.as_any().downcast_ref::<StringViewArray>() {
        return values.value(index).to_string();
    }
    String::new()
}

fn offset_bytes(array: &dyn Array, rows: usize) -> Result<(&'static str, Vec<u8>), String> {
    if let Some(values) = array.as_any().downcast_ref::<Int32Array>() {
        return pack_named("list32", values.values(), rows);
    }
    if let Some(values) = array.as_any().downcast_ref::<Int64Array>() {
        return pack_named("list64", values.values(), rows);
    }
    Err("list offsets are not int32 or int64".to_string())
}

fn pack_named<T: LeBytes>(
    kind: &'static str,
    values: &[T],
    rows: usize,
) -> Result<(&'static str, Vec<u8>), String> {
    if values.len() != rows + 1 {
        return Err("list offset length does not match the row count".to_string());
    }
    Ok((kind, le_bytes(values)))
}

fn bin_col(kind: &'static str, rows: usize, values: Vec<u8>, validity: Option<Vec<u8>>) -> OwnedCol {
    OwnedCol {
        kind,
        rows,
        values: Values::Bytes(values),
        validity,
    }
}

fn validity_bytes(array: &dyn Array) -> Option<Vec<u8>> {
    let nulls = array.nulls()?;
    if nulls.null_count() == 0 {
        return None;
    }
    Some(
        (0..array.len())
            .map(|i| u8::from(array.is_valid(i)))
            .collect(),
    )
}

fn blank_if_full(validity: Option<Vec<u8>>, rows: usize) -> Option<Vec<u8>> {
    match validity {
        Some(bytes) if bytes.len() == rows && bytes.iter().all(|byte| *byte == 1) => None,
        other => other,
    }
}

fn show(err: impl ToString) -> String {
    let mut text: String = err
        .to_string()
        .chars()
        .filter(|ch| !ch.is_control())
        .take(180)
        .collect();
    if text.is_empty() {
        text = "decode failed".to_string();
    }
    text
}
