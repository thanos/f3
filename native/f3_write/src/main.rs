//! Out-of-process F3 writer. Mix copies this file to `fff-poc/src/bin/f3_write.rs`
//! and builds it with the pinned checkout's Cargo.lock. The NIF does not link it.

use std::fs::File;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Arc;

use arrow_array::{
    ArrayRef, BooleanArray, Float32Array, Float64Array, Int32Array, Int64Array, ListArray,
    RecordBatch, StringArray, StructArray, UInt16Array, UInt32Array, UInt64Array, UInt8Array,
};
use arrow_buffer::{BooleanBufferBuilder, NullBuffer, OffsetBuffer, ScalarBuffer};
use arrow_schema::{DataType, Field, Fields, Schema, SchemaRef};
use fff_format::File::fff::flatbuf::CompressionType;
use fff_poc::options::FileWriterOptions;
use fff_poc::reader::FileReaderV2Builder;
use fff_poc::writer::FileWriter;

const TAG_SCHEMA: u8 = 1;
const TAG_BATCH: u8 = 2;
const TAG_FINISH: u8 = 3;

const TY_BOOL: u8 = 1;
const TY_UTF8: u8 = 2;
const TY_I64: u8 = 3;
const TY_I32: u8 = 4;
const TY_U64: u8 = 5;
const TY_U32: u8 = 6;
const TY_U16: u8 = 7;
const TY_U8: u8 = 8;
const TY_F64: u8 = 9;
const TY_F32: u8 = 10;
const TY_LIST: u8 = 11;
const TY_STRUCT: u8 = 12;

struct Cursor<'a> {
    buf: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn rest(&self) -> usize {
        self.buf.len().saturating_sub(self.at)
    }

    fn u8(&mut self) -> Result<u8, String> {
        let byte = *self.buf.get(self.at).ok_or("truncated")?;
        self.at += 1;
        Ok(byte)
    }

    fn u16(&mut self) -> Result<u16, String> {
        let bytes = self.bytes(2)?;
        Ok(u16::from_le_bytes(bytes.try_into().unwrap()))
    }

    fn u32(&mut self) -> Result<u32, String> {
        let bytes = self.bytes(4)?;
        Ok(u32::from_le_bytes(bytes.try_into().unwrap()))
    }

    fn bytes(&mut self, len: usize) -> Result<&'a [u8], String> {
        let end = self.at.checked_add(len).ok_or("truncated")?;
        let slice = self.buf.get(self.at..end).ok_or("truncated")?;
        self.at = end;
        Ok(slice)
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let command = args.next().unwrap_or_default();
    let code = match command.as_str() {
        "read" => read_main(args.collect()),
        "write" => write_main(args.collect()),
        _ => {
            eprintln!("usage: f3_write read [--verify] <path> | f3_write write [options] <path>");
            2
        }
    };
    std::process::exit(code);
}

fn read_main(args: Vec<String>) -> i32 {
    let mut verify = false;
    let mut path = None;
    for arg in args {
        match arg.as_str() {
            "--verify" => verify = true,
            other if path.is_none() => path = Some(other.to_string()),
            _ => return reply_fail("read", "invalid argument"),
        }
    }
    let Some(path) = path else {
        return reply_fail("read", "path is required");
    };
    match read_rows(&path, verify) {
        Ok(bytes) => {
            let _ = std::io::stdout().write_all(&bytes);
            let _ = std::io::stdout().write_all(b"\n");
            0
        }
        Err(err) => reply_fail("read", &err),
    }
}

fn read_rows(path: &str, verify: bool) -> Result<Vec<u8>, String> {
    let file = File::open(path).map_err(|_| "reader io".to_string())?;
    let mut reader = FileReaderV2Builder::new(Arc::new(file))
        .with_verify_io_unit_checksum(verify)
        .build()
        .map_err(|err| sanitize(&err.to_string(), path))?;
    let batches = reader
        .read_file()
        .map_err(|err| sanitize(&err.to_string(), path))?;
    let refs: Vec<_> = batches.iter().collect();
    let mut writer = arrow_json::WriterBuilder::new()
        .with_explicit_nulls(true)
        .build::<_, arrow_json::writer::JsonArray>(Vec::<u8>::new());
    writer
        .write_batches(&refs)
        .map_err(|err| sanitize(&err.to_string(), path))?;
    writer.finish().map_err(|err| sanitize(&err.to_string(), path))?;
    Ok(writer.into_inner())
}

struct WriteOpts {
    compression: CompressionType,
    iounit_bytes: u64,
    row_group_rows: Option<u64>,
    checksum: bool,
    path: PathBuf,
}

fn write_main(args: Vec<String>) -> i32 {
    let opts = match parse_write(args) {
        Ok(opts) => opts,
        Err(err) => return reply_fail("write", &err),
    };
    let path_text = opts.path.display().to_string();
    let file = match File::create(&opts.path) {
        Ok(file) => file,
        Err(_) => return reply_fail("write", "writer io"),
    };
    if let Err(err) = write_loop(file, &opts, &path_text) {
        return reply_fail("write", &err);
    }
    0
}

fn parse_write(args: Vec<String>) -> Result<WriteOpts, String> {
    let mut compression = CompressionType::Uncompressed;
    let mut iounit_bytes = 8 * 1024 * 1024;
    let mut row_group_rows = None;
    let mut checksum = false;
    let mut path = None;
    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--compression" => {
                compression = match iter.next().as_deref() {
                    Some("uncompressed") => CompressionType::Uncompressed,
                    Some("lz4") => CompressionType::Lz4,
                    Some("zstd") => CompressionType::Zstd,
                    _ => return Err("invalid compression".to_string()),
                }
            }
            "--iounit-bytes" => {
                iounit_bytes = iter
                    .next()
                    .ok_or("truncated")?
                    .parse()
                    .map_err(|_| "invalid iounit".to_string())?;
            }
            "--row-group-rows" => {
                row_group_rows = Some(
                    iter.next()
                        .ok_or("truncated")?
                        .parse()
                        .map_err(|_| "invalid row group".to_string())?,
                );
            }
            "--checksum" => checksum = true,
            other if !other.starts_with("--") && path.is_none() => path = Some(PathBuf::from(other)),
            _ => return Err("invalid argument".to_string()),
        }
    }
    Ok(WriteOpts {
        compression,
        iounit_bytes,
        row_group_rows,
        checksum,
        path: path.ok_or("path is required")?,
    })
}

fn write_loop(file: File, opts: &WriteOpts, path_text: &str) -> Result<(), String> {
    let mut stdin = std::io::stdin().lock();
    let frame = read_packet(&mut stdin)?;
    let mut cursor = Cursor { buf: &frame, at: 0 };
    if cursor.u8()? != TAG_SCHEMA {
        return Err("schema is required".to_string());
    }
    let schema = decode_schema(&mut cursor)?;
    if cursor.rest() != 0 {
        return Err("truncated".to_string());
    }
    let mut options = FileWriterOptions::builder()
        .set_compression_type(opts.compression)
        .set_iounit_size(opts.iounit_bytes)
        .enable_io_unit_checksum(opts.checksum);
    if let Some(rows) = opts.row_group_rows {
        options = options.set_row_group_size(rows);
    }
    let mut writer = FileWriter::try_new(schema.clone(), file, options.build())
        .map_err(|err| sanitize(&err.to_string(), path_text))?;
    write_packet(b"ok")?;

    loop {
        let frame = read_packet(&mut stdin)?;
        let mut cursor = Cursor { buf: &frame, at: 0 };
        match cursor.u8()? {
            TAG_BATCH => {
                let batch = decode_batch(&mut cursor, schema.as_ref())?;
                if cursor.rest() != 0 {
                    return Err("truncated".to_string());
                }
                writer
                    .write_batch(&batch)
                    .map_err(|err| sanitize(&err.to_string(), path_text))?;
                write_packet(b"ok")?;
            }
            TAG_FINISH => {
                let fail = cursor.u8().unwrap_or(0);
                if fail == 1 {
                    return Err("finish failed".to_string());
                }
                writer
                    .finish()
                    .map_err(|err| sanitize(&err.to_string(), path_text))?;
                write_packet(b"ok")?;
                return Ok(());
            }
            _ => return Err("invalid frame".to_string()),
        }
    }
}

fn decode_schema(cursor: &mut Cursor<'_>) -> Result<SchemaRef, String> {
    let count = cursor.u32()? as usize;
    let mut fields = Vec::with_capacity(count);
    for _ in 0..count {
        fields.push(decode_field(cursor)?);
    }
    Ok(Arc::new(Schema::new(fields)))
}

fn decode_field(cursor: &mut Cursor<'_>) -> Result<Field, String> {
    let name_len = cursor.u16()? as usize;
    let name = std::str::from_utf8(cursor.bytes(name_len)?).map_err(|_| "schema".to_string())?;
    let nullable = cursor.u8()? == 1;
    let (dtype, _) = decode_type(cursor)?;
    Ok(Field::new(name, dtype, nullable))
}

fn decode_type(cursor: &mut Cursor<'_>) -> Result<(DataType, bool), String> {
    match cursor.u8()? {
        TY_BOOL => Ok((DataType::Boolean, true)),
        TY_UTF8 => Ok((DataType::Utf8, true)),
        TY_I64 => Ok((DataType::Int64, true)),
        TY_I32 => Ok((DataType::Int32, true)),
        TY_U64 => Ok((DataType::UInt64, true)),
        TY_U32 => Ok((DataType::UInt32, true)),
        TY_U16 => Ok((DataType::UInt16, true)),
        TY_U8 => Ok((DataType::UInt8, true)),
        TY_F64 => Ok((DataType::Float64, true)),
        TY_F32 => Ok((DataType::Float32, true)),
        TY_LIST => {
            let child = decode_field(cursor)?;
            Ok((DataType::List(Arc::new(child)), true))
        }
        TY_STRUCT => {
            let count = cursor.u16()? as usize;
            let mut fields = Vec::with_capacity(count);
            for _ in 0..count {
                fields.push(decode_field(cursor)?);
            }
            Ok((DataType::Struct(Fields::from(fields)), true))
        }
        _ => Err("schema".to_string()),
    }
}

fn decode_batch(cursor: &mut Cursor<'_>, schema: &Schema) -> Result<RecordBatch, String> {
    let rows = cursor.u32()? as usize;
    let mut columns = Vec::with_capacity(schema.fields().len());
    for field in schema.fields() {
        columns.push(decode_column(cursor, field, rows)?);
    }
    RecordBatch::try_new(Arc::new(schema.clone()), columns).map_err(|_| "batch".to_string())
}

fn decode_column(cursor: &mut Cursor<'_>, field: &Field, rows: usize) -> Result<ArrayRef, String> {
    let validity_len = cursor.u32()? as usize;
    let validity = cursor.bytes(validity_len)?;
    if validity_len != 0 && validity_len != rows {
        return Err("batch".to_string());
    }
    let nulls = nulls_from(validity, rows)?;
    match field.data_type() {
        DataType::Boolean => {
            let bytes = cursor.bytes(rows)?;
            Ok(Arc::new(BooleanArray::new(bools(bytes)?, nulls)))
        }
        DataType::Utf8 => {
            let count = cursor.u32()? as usize;
            if count != rows {
                return Err("batch".to_string());
            }
            let mut offsets = Vec::with_capacity(rows + 1);
            let mut data = Vec::new();
            offsets.push(0i32);
            for _ in 0..rows {
                let len = cursor.u32()? as usize;
                data.extend_from_slice(cursor.bytes(len)?);
                offsets.push(data.len() as i32);
            }
            let array = StringArray::try_new(
                OffsetBuffer::new(ScalarBuffer::from(offsets)),
                data.into(),
                nulls,
            )
            .map_err(|_| "batch".to_string())?;
            Ok(Arc::new(array))
        }
        DataType::Int64 => signed(cursor, rows, nulls, 8, |v| v, |v| Arc::new(Int64Array::from(v))),
        DataType::Int32 => {
            signed(cursor, rows, nulls, 4, |v| v as i32, |v| Arc::new(Int32Array::from(v)))
        }
        DataType::UInt64 => unsigned(cursor, rows, nulls, 8, |v| v, |v| Arc::new(UInt64Array::from(v))),
        DataType::UInt32 => {
            unsigned(cursor, rows, nulls, 4, |v| v as u32, |v| Arc::new(UInt32Array::from(v)))
        }
        DataType::UInt16 => {
            unsigned(cursor, rows, nulls, 2, |v| v as u16, |v| Arc::new(UInt16Array::from(v)))
        }
        DataType::UInt8 => unsigned(cursor, rows, nulls, 1, |v| v as u8, |v| Arc::new(UInt8Array::from(v))),
        DataType::Float64 => {
            let bytes = cursor.bytes(rows * 8)?;
            let values = optional_chunks(bytes, 8, &nulls, |chunk| {
                f64::from_le_bytes(chunk.try_into().unwrap())
            });
            Ok(Arc::new(Float64Array::from(values)))
        }
        DataType::Float32 => {
            let bytes = cursor.bytes(rows * 4)?;
            let values = optional_chunks(bytes, 4, &nulls, |chunk| {
                f32::from_le_bytes(chunk.try_into().unwrap())
            });
            Ok(Arc::new(Float32Array::from(values)))
        }
        DataType::List(child) => {
            let width = cursor.u8()?;
            let points = rows + 1;
            let raw = cursor.bytes(points * width as usize)?;
            let offsets = match width {
                4 => offset_buffer::<i32>(raw, points)?,
                8 => return Err("batch".to_string()),
                _ => return Err("batch".to_string()),
            };
            let child_rows = *offsets.last().ok_or("batch")? as usize;
            let values = decode_column(cursor, child.as_ref(), child_rows)?;
            let array = ListArray::try_new(Arc::clone(child), offsets, values, nulls)
                .map_err(|_| "batch".to_string())?;
            Ok(Arc::new(array))
        }
        DataType::Struct(children) => {
            let mut arrays = Vec::with_capacity(children.len());
            for child in children {
                arrays.push(decode_column(cursor, child.as_ref(), rows)?);
            }
            let array = StructArray::try_new(children.clone(), arrays, nulls)
                .map_err(|_| "batch".to_string())?;
            Ok(Arc::new(array))
        }
        _ => Err("schema".to_string()),
    }
}

fn signed<T, F>(
    cursor: &mut Cursor<'_>,
    rows: usize,
    nulls: Option<NullBuffer>,
    width: usize,
    cast: fn(i64) -> T,
    build: F,
) -> Result<ArrayRef, String>
where
    F: FnOnce(Vec<Option<T>>) -> ArrayRef,
{
    let bytes = cursor.bytes(rows * width)?;
    let values = optional_chunks(bytes, width, &nulls, |chunk| cast(le_signed(chunk)));
    Ok(build(values))
}

fn unsigned<T, F>(
    cursor: &mut Cursor<'_>,
    rows: usize,
    nulls: Option<NullBuffer>,
    width: usize,
    cast: fn(u64) -> T,
    build: F,
) -> Result<ArrayRef, String>
where
    F: FnOnce(Vec<Option<T>>) -> ArrayRef,
{
    let bytes = cursor.bytes(rows * width)?;
    let values = optional_chunks(bytes, width, &nulls, |chunk| cast(le_unsigned(chunk)));
    Ok(build(values))
}

fn le_signed(chunk: &[u8]) -> i64 {
    match chunk.len() {
        8 => i64::from_le_bytes(chunk.try_into().unwrap()),
        4 => i32::from_le_bytes(chunk.try_into().unwrap()) as i64,
        _ => unreachable!(),
    }
}

fn le_unsigned(chunk: &[u8]) -> u64 {
    match chunk.len() {
        8 => u64::from_le_bytes(chunk.try_into().unwrap()),
        4 => u32::from_le_bytes(chunk.try_into().unwrap()) as u64,
        2 => u16::from_le_bytes(chunk.try_into().unwrap()) as u64,
        1 => chunk[0] as u64,
        _ => unreachable!(),
    }
}

fn optional_chunks<T>(
    bytes: &[u8],
    width: usize,
    nulls: &Option<NullBuffer>,
    cast: impl Fn(&[u8]) -> T,
) -> Vec<Option<T>> {
    bytes
        .chunks_exact(width)
        .enumerate()
        .map(|(index, chunk)| {
            let present = match nulls {
                Some(nulls) => nulls.is_valid(index),
                None => true,
            };
            present.then(|| cast(chunk))
        })
        .collect()
}

fn nulls_from(validity: &[u8], rows: usize) -> Result<Option<NullBuffer>, String> {
    if validity.is_empty() {
        return Ok(None);
    }
    let mut bits = BooleanBufferBuilder::new(rows);
    for byte in validity {
        bits.append(*byte != 0);
    }
    Ok(Some(NullBuffer::new(bits.finish())))
}

fn bools(bytes: &[u8]) -> Result<arrow_buffer::BooleanBuffer, String> {
    let mut bits = BooleanBufferBuilder::new(bytes.len());
    for byte in bytes {
        bits.append(*byte != 0);
    }
    Ok(bits.finish())
}

fn offset_buffer<T>(raw: &[u8], points: usize) -> Result<OffsetBuffer<i32>, String> {
    if std::mem::size_of::<T>() != 4 || raw.len() != points * 4 {
        return Err("batch".to_string());
    }
    let mut values = Vec::with_capacity(points);
    for chunk in raw.chunks_exact(4) {
        values.push(i32::from_le_bytes(chunk.try_into().unwrap()));
    }
    Ok(OffsetBuffer::new(ScalarBuffer::from(values)))
}

fn read_packet(stdin: &mut impl Read) -> Result<Vec<u8>, String> {
    let mut len_buf = [0u8; 4];
    stdin.read_exact(&mut len_buf).map_err(|_| "truncated".to_string())?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > 64 * 1024 * 1024 {
        return Err("resource limit".to_string());
    }
    let mut buf = vec![0u8; len];
    stdin.read_exact(&mut buf).map_err(|_| "truncated".to_string())?;
    Ok(buf)
}

fn write_packet(payload: &[u8]) -> Result<(), String> {
    let mut stdout = std::io::stdout().lock();
    let len = (payload.len() as u32).to_be_bytes();
    stdout.write_all(&len).map_err(|_| "writer io".to_string())?;
    stdout.write_all(payload).map_err(|_| "writer io".to_string())?;
    stdout.flush().map_err(|_| "writer io".to_string())?;
    Ok(())
}

fn reply_fail(kind: &str, message: &str) -> i32 {
    let text = format!("err {kind} {message}");
    let _ = write_packet(text.as_bytes());
    let _ = writeln!(std::io::stderr(), "{text}");
    1
}

fn sanitize(message: &str, path: &str) -> String {
    let message = message.replace(path, "file");
    message
        .chars()
        .filter(|c| c.is_ascii() && !c.is_control())
        .take(180)
        .collect()
}
