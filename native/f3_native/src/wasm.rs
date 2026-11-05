//! Opt-in Wasmtime 28 host for one `decode_general_ffi` call.
//!
//! The engine is process-local. It is not the upstream `fff-ude-wasm` global,
//! and this crate does not link `fff-poc`. A module is compiled only after
//! Elixir has already decided the caller passed `wasm: :sandbox`. WASI gets
//! size-capped stdout and stderr sinks. There is no preopened directory and
//! the process environment is not inherited. Fuel is this library's cap.
//! Upstream Wasmtime use in F3 sets none.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use arrow_array::{
    ArrayRef, BooleanArray, Float32Array, Float64Array, Int32Array, Int64Array, StringArray,
    UInt16Array, UInt32Array, UInt64Array, UInt8Array,
};
use arrow_buffer::{BooleanBuffer, Buffer, NullBuffer, OffsetBuffer, ScalarBuffer};
use sha2::{Digest, Sha256};
use wasi_common::pipe::WritePipe;
use wasi_common::sync::WasiCtxBuilder;
use wasi_common::WasiCtx;
use wasmtime::{
    Engine, Linker, Module, Store, StoreLimits, StoreLimitsBuilder,
};

use crate::decode::{self, Compression, OwnedCol};

const FUEL: u64 = 5_000_000;
const MEMORY_BYTES: usize = 8 * 1024 * 1024;
const HARD_MODULE_BYTES: usize = 16 * 1024 * 1024;
const CACHE_MODULES: usize = 8;
const CACHE_BYTES: usize = 8 * 1024 * 1024;
const INPUT_ALIGNMENT: u32 = 4;
const MAX_BUFFERS: usize = 16;

const REQUIRED: &[&str] = &[
    "alloc",
    "dealloc",
    "decode_general_ffi",
    "buffer_iterator_next",
    "buffer_iterator_drop",
    "buffer_drop",
    "memory",
];

const FORBIDDEN: &[&str] = &[
    "path_open",
    "path_create_directory",
    "path_filestat_get",
    "path_remove_directory",
    "path_unlink_file",
    "path_rename",
    "path_link",
    "path_symlink",
    "sock_accept",
    "sock_recv",
    "sock_send",
    "sock_shutdown",
];

struct Host {
    wasi: WasiCtx,
    limits: StoreLimits,
}

struct Cached {
    module: Module,
    bytes: usize,
}

struct Cache {
    modules: HashMap<[u8; 32], Cached>,
    total: usize,
}

fn cache() -> &'static Mutex<Cache> {
    static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
    CACHE.get_or_init(|| {
        Mutex::new(Cache {
            modules: HashMap::new(),
            total: 0,
        })
    })
}

fn engine() -> Result<&'static Engine, String> {
    static ENGINE: OnceLock<Result<Engine, String>> = OnceLock::new();
    match ENGINE.get_or_init(|| {
        let mut config = wasmtime::Config::new();
        config.consume_fuel(true);
        config.parallel_compilation(false);
        Engine::new(&config).map_err(|_| "wasm module".to_string())
    }) {
        Ok(engine) => Ok(engine),
        Err(message) => Err(message.clone()),
    }
}

pub fn clear_cache() {
    if let Ok(mut cache) = cache().lock() {
        cache.modules.clear();
        cache.total = 0;
    }
}

pub fn invalidate(bytes: &[u8]) {
    let key = hash(bytes);
    if let Ok(mut cache) = cache().lock() {
        if let Some(entry) = cache.modules.remove(&key) {
            cache.total = cache.total.saturating_sub(entry.bytes);
        }
    }
}

pub fn decode(
    module_bytes: &[u8],
    payload: Vec<u8>,
    compression: Compression,
    arrow_type: &str,
    rows: usize,
) -> Result<OwnedCol, String> {
    if module_bytes.len() > HARD_MODULE_BYTES {
        return Err("module bytes".to_string());
    }
    let plain = decode::decompress(compression, payload)?;
    let module = load_module(module_bytes)?;
    check_abi(&module)?;
    check_imports(&module)?;
    let buffers = invoke(&module, &plain)?;
    arrays(arrow_type, rows, buffers)
}

fn load_module(bytes: &[u8]) -> Result<Module, String> {
    let key = hash(bytes);
    let engine = engine()?;
    if let Ok(cache) = cache().lock() {
        if let Some(entry) = cache.modules.get(&key) {
            return Ok(entry.module.clone());
        }
    }
    let module = Module::new(engine, bytes).map_err(|_| "wasm module".to_string())?;
    remember(key, &module, bytes.len());
    Ok(module)
}

fn remember(key: [u8; 32], module: &Module, bytes: usize) {
    let Ok(mut cache) = cache().lock() else {
        return;
    };
    if cache.modules.contains_key(&key) {
        return;
    }
    if cache.modules.len() >= CACHE_MODULES || cache.total.saturating_add(bytes) > CACHE_BYTES {
        return;
    }
    cache.total = cache.total.saturating_add(bytes);
    cache.modules.insert(
        key,
        Cached {
            module: module.clone(),
            bytes,
        },
    );
}

fn hash(bytes: &[u8]) -> [u8; 32] {
    let digest = Sha256::digest(bytes);
    let mut key = [0u8; 32];
    key.copy_from_slice(&digest);
    key
}

fn check_abi(module: &Module) -> Result<(), String> {
    let mut major_ok = false;
    for export in module.exports() {
        let Some(rest) = export.name().strip_prefix("FFFUDE_VERSION_") else {
            continue;
        };
        let major = rest
            .split('_')
            .next()
            .unwrap_or("")
            .parse::<u32>()
            .map_err(|_| "bad abi".to_string())?;
        if major != 1 {
            return Err("bad abi".to_string());
        }
        major_ok = true;
    }
    if !major_ok {
        return Err("bad abi".to_string());
    }
    for name in REQUIRED {
        if !module.exports().any(|export| export.name() == *name) {
            return Err("missing export".to_string());
        }
    }
    Ok(())
}

fn check_imports(module: &Module) -> Result<(), String> {
    for import in module.imports() {
        let module_name = import.module();
        if module_name != "wasi_snapshot_preview1" && module_name != "wasi_unstable" {
            return Err("wasm import".to_string());
        }
        if FORBIDDEN.iter().any(|name| *name == import.name()) {
            return Err("wasm import".to_string());
        }
    }
    Ok(())
}

fn invoke(module: &Module, input: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    let engine = module.engine();
    let wasi = WasiCtxBuilder::new()
        .stdout(Box::new(WritePipe::new(std::io::sink())))
        .stderr(Box::new(WritePipe::new(std::io::sink())))
        .build();
    let limits = StoreLimitsBuilder::new()
        .memory_size(MEMORY_BYTES)
        .memories(1)
        .instances(16)
        .tables(8)
        .table_elements(16_384)
        .trap_on_grow_failure(true)
        .build();
    let mut store = Store::new(engine, Host { wasi, limits });
    store.limiter(|host| &mut host.limits);
    store.set_fuel(FUEL).map_err(classify)?;

    let mut linker = Linker::new(engine);
    wasi_common::sync::add_to_linker(&mut linker, |host: &mut Host| &mut host.wasi)
        .map_err(|_| "wasm import".to_string())?;
    let instance = linker
        .instantiate(&mut store, module)
        .map_err(classify)?;
    let memory = instance
        .get_memory(&mut store, "memory")
        .ok_or_else(|| "missing export".to_string())?;

    let alloc = instance
        .get_typed_func::<(u32, u32), u32>(&mut store, "alloc")
        .map_err(|_| "missing export".to_string())?;
    let dealloc = instance
        .get_typed_func::<(u32, u32, u32), ()>(&mut store, "dealloc")
        .map_err(|_| "missing export".to_string())?;
    let decode = instance
        .get_typed_func::<(u32, u32, u32), i32>(&mut store, "decode_general_ffi")
        .map_err(|_| "missing export".to_string())?;
    let next = instance
        .get_typed_func::<(u32, u32, u32), ()>(&mut store, "buffer_iterator_next")
        .map_err(|_| "missing export".to_string())?;
    let drop_iter = instance
        .get_typed_func::<u32, ()>(&mut store, "buffer_iterator_drop")
        .map_err(|_| "missing export".to_string())?;
    let drop_buf = instance
        .get_typed_func::<u32, ()>(&mut store, "buffer_drop")
        .map_err(|_| "missing export".to_string())?;

    let alloc_len = u32::try_from(input.len() + 12).map_err(|_| "wasm trap".to_string())?;
    let alloc_ptr = alloc
        .call(&mut store, (alloc_len, INPUT_ALIGNMENT))
        .map_err(classify)?;
    if alloc_ptr == 0 {
        return Err("wasm trap".to_string());
    }
    let in_ptr = alloc_ptr + 12;
    memory
        .write(&mut store, in_ptr as usize, input)
        .map_err(|_| "wasm trap".to_string())?;
    let errno = decode
        .call(&mut store, (in_ptr, input.len() as u32, alloc_ptr))
        .map_err(classify)?;
    if errno != 0 {
        return Err("wasm trap".to_string());
    }
    let iter_ptr = read_u32(&memory, &store, alloc_ptr)?;
    let mut buffers = Vec::new();
    for _ in 0..MAX_BUFFERS {
        next.call(&mut store, (iter_ptr, alloc_ptr, alloc_ptr + 8))
            .map_err(classify)?;
        let out_ptr = read_u32(&memory, &store, alloc_ptr)?;
        let out_len = read_u32(&memory, &store, alloc_ptr + 4)?;
        let box_ptr = read_u32(&memory, &store, alloc_ptr + 8)?;
        if out_ptr == 0 {
            break;
        }
        if out_len as usize > MEMORY_BYTES {
            return Err("memory limit".to_string());
        }
        let bytes = memory
            .data(&store)
            .get(out_ptr as usize..(out_ptr + out_len) as usize)
            .ok_or_else(|| "wasm trap".to_string())?
            .to_vec();
        if box_ptr != 0 {
            drop_buf.call(&mut store, box_ptr).map_err(classify)?;
        }
        buffers.push(bytes);
    }
    drop_iter.call(&mut store, iter_ptr).map_err(classify)?;
    dealloc
        .call(&mut store, (alloc_ptr, alloc_len, INPUT_ALIGNMENT))
        .map_err(classify)?;
    Ok(buffers)
}

fn read_u32(memory: &wasmtime::Memory, store: &Store<Host>, ptr: u32) -> Result<u32, String> {
    let mut buf = [0u8; 4];
    memory
        .read(store, ptr as usize, &mut buf)
        .map_err(|_| "wasm trap".to_string())?;
    Ok(u32::from_le_bytes(buf))
}

fn arrays(arrow_type: &str, rows: usize, buffers: Vec<Vec<u8>>) -> Result<OwnedCol, String> {
    let array = match arrow_type {
        "i64" => primitive_i64(rows, &buffers)?,
        "i32" => primitive_i32(rows, &buffers)?,
        "u64" => primitive_u64(rows, &buffers)?,
        "u32" => primitive_u32(rows, &buffers)?,
        "u16" => primitive_u16(rows, &buffers)?,
        "u8" => primitive_u8(rows, &buffers)?,
        "f64" => primitive_f64(rows, &buffers)?,
        "f32" => primitive_f32(rows, &buffers)?,
        "bool" => primitive_bool(rows, &buffers)?,
        "utf8" => utf8_array(rows, &buffers)?,
        "integer" | "list32" | "list64" => return Err("nested wasm".to_string()),
        _ => return Err("unknown arrow type".to_string()),
    };
    decode::export_array(array)
}

fn take2(buffers: &[Vec<u8>]) -> Result<(&[u8], &[u8]), String> {
    match buffers {
        [validity, data] => Ok((validity, data)),
        _ => Err("output length".to_string()),
    }
}

fn primitive_i64(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, rows.checked_mul(8).ok_or_else(|| "output length".to_string())?)?;
    let values = ScalarBuffer::<i64>::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(Int64Array::new(values, nulls(validity, rows)?)))
}

fn primitive_i32(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, rows.checked_mul(4).ok_or_else(|| "output length".to_string())?)?;
    let values = ScalarBuffer::<i32>::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(Int32Array::new(values, nulls(validity, rows)?)))
}

fn primitive_u64(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, rows.checked_mul(8).ok_or_else(|| "output length".to_string())?)?;
    let values = ScalarBuffer::<u64>::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(UInt64Array::new(values, nulls(validity, rows)?)))
}

fn primitive_u32(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, rows.checked_mul(4).ok_or_else(|| "output length".to_string())?)?;
    let values = ScalarBuffer::<u32>::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(UInt32Array::new(values, nulls(validity, rows)?)))
}

fn primitive_u16(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, rows.checked_mul(2).ok_or_else(|| "output length".to_string())?)?;
    let values = ScalarBuffer::<u16>::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(UInt16Array::new(values, nulls(validity, rows)?)))
}

fn primitive_u8(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, rows)?;
    let values = ScalarBuffer::<u8>::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(UInt8Array::new(values, nulls(validity, rows)?)))
}

fn primitive_f64(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, rows.checked_mul(8).ok_or_else(|| "output length".to_string())?)?;
    let values = ScalarBuffer::<f64>::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(Float64Array::new(
        values,
        nulls(validity, rows)?,
    )))
}

fn primitive_f32(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, rows.checked_mul(4).ok_or_else(|| "output length".to_string())?)?;
    let values = ScalarBuffer::<f32>::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(Float32Array::new(
        values,
        nulls(validity, rows)?,
    )))
}

fn primitive_bool(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let (validity, data) = take2(buffers)?;
    expect_len(data, bits_len(rows))?;
    let flags = BooleanBuffer::new(Buffer::from(data.to_vec()), 0, rows);
    Ok(std::sync::Arc::new(BooleanArray::new(
        flags,
        nulls(validity, rows)?,
    )))
}

fn utf8_array(rows: usize, buffers: &[Vec<u8>]) -> Result<ArrayRef, String> {
    let [validity, offsets, data] = buffers else {
        return Err("output length".to_string());
    };
    let count = rows.checked_add(1).ok_or_else(|| "output length".to_string())?;
    expect_len(offsets, count.checked_mul(4).ok_or_else(|| "output length".to_string())?)?;
    let offsets = ScalarBuffer::<i32>::new(Buffer::from(offsets.clone()), 0, count);
    let offsets = OffsetBuffer::new(offsets);
    StringArray::try_new(offsets, Buffer::from(data.clone()), nulls(validity, rows)?)
        .map(|array| std::sync::Arc::new(array) as ArrayRef)
        .map_err(|_| "output length".to_string())
}

fn nulls(validity: &[u8], rows: usize) -> Result<Option<NullBuffer>, String> {
    if validity.is_empty() {
        return Ok(None);
    }
    expect_len(validity, bits_len(rows))?;
    Ok(Some(NullBuffer::new(BooleanBuffer::new(
        Buffer::from(validity.to_vec()),
        0,
        rows,
    ))))
}

fn bits_len(rows: usize) -> usize {
    rows.div_ceil(8)
}

fn expect_len(bytes: &[u8], len: usize) -> Result<(), String> {
    if bytes.len() == len {
        Ok(())
    } else {
        Err("output length".to_string())
    }
}

fn classify(err: impl std::fmt::Debug + ToString) -> String {
    let debug = format!("{err:?}").to_ascii_lowercase();
    let text = err.to_string().to_ascii_lowercase();
    let combined = format!("{text} {debug}");
    if combined.contains("fuel") {
        "fuel exhausted".to_string()
    } else if combined.contains("memory") || combined.contains("limiter") {
        "memory limit".to_string()
    } else {
        "wasm trap".to_string()
    }
}

pub fn sample(name: &str) -> Result<Vec<u8>, String> {
    let wat = match name {
        "ok_i64" => OK_I64,
        "short" => SHORT_I64,
        "fuel" => FUEL_LOOP,
        "memory" => BIG_MEMORY,
        "grow" => GROW_MEMORY,
        "import" => PATH_OPEN,
        "socket" => SOCKET,
        "abi" => NO_ABI,
        "major" => MAJOR_TWO,
        _ => return Err("unknown sample".to_string()),
    };
    wat::parse_str(wat).map_err(|_| "wasm module".to_string())
}

const OK_I64: &str = r#"
(module
  (memory (export "memory") 1)
  (global (export "FFFUDE_VERSION_1_0") i32 (i32.const 0))
  (global $i (mut i32) (i32.const 0))
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32)
    (i32.store (local.get 2) (i32.const 128))
    (i32.store (i32.add (local.get 2) (i32.const 4)) (i32.const 4))
    (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32)
    (if (i32.eq (global.get $i) (i32.const 0))
      (then
        (i32.store (local.get 1) (i32.const 256))
        (i32.store (i32.add (local.get 1) (i32.const 4)) (i32.const 0))
        (i32.store (local.get 2) (i32.const 1))
        (global.set $i (i32.const 1)))
      (else
        (if (i32.eq (global.get $i) (i32.const 1))
          (then
            (i64.store (i32.const 256) (i64.const 1))
            (i64.store (i32.const 264) (i64.const 2))
            (i64.store (i32.const 272) (i64.const 3))
            (i32.store (local.get 1) (i32.const 256))
            (i32.store (i32.add (local.get 1) (i32.const 4)) (i32.const 24))
            (i32.store (local.get 2) (i32.const 1))
            (global.set $i (i32.const 2)))
          (else
            (i32.store (local.get 1) (i32.const 0))
            (i32.store (i32.add (local.get 1) (i32.const 4)) (i32.const 0)))))))
)
"#;

const SHORT_I64: &str = r#"
(module
  (memory (export "memory") 1)
  (global (export "FFFUDE_VERSION_1_0") i32 (i32.const 0))
  (global $i (mut i32) (i32.const 0))
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32)
    (i32.store (local.get 2) (i32.const 128))
    (i32.store (i32.add (local.get 2) (i32.const 4)) (i32.const 4))
    (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32)
    (if (i32.eq (global.get $i) (i32.const 0))
      (then
        (i32.store (local.get 1) (i32.const 256))
        (i32.store (i32.add (local.get 1) (i32.const 4)) (i32.const 0))
        (i32.store (local.get 2) (i32.const 1))
        (global.set $i (i32.const 1)))
      (else
        (if (i32.eq (global.get $i) (i32.const 1))
          (then
            (i32.store (local.get 1) (i32.const 256))
            (i32.store (i32.add (local.get 1) (i32.const 4)) (i32.const 8))
            (i32.store (local.get 2) (i32.const 1))
            (global.set $i (i32.const 2)))
          (else
            (i32.store (local.get 1) (i32.const 0))
            (i32.store (i32.add (local.get 1) (i32.const 4)) (i32.const 0)))))))
)
"#;

const FUEL_LOOP: &str = r#"
(module
  (memory (export "memory") 1)
  (global (export "FFFUDE_VERSION_1_0") i32 (i32.const 0))
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32)
    (loop $forever (br $forever))
    (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32))
)
"#;

const BIG_MEMORY: &str = r#"
(module
  (memory (export "memory") 256)
  (global (export "FFFUDE_VERSION_1_0") i32 (i32.const 0))
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32) (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32))
)
"#;

const GROW_MEMORY: &str = r#"
(module
  (memory (export "memory") 1)
  (global (export "FFFUDE_VERSION_1_0") i32 (i32.const 0))
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32)
    (drop (memory.grow (i32.const 200)))
    (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32))
)
"#;

const PATH_OPEN: &str = r#"
(module
  (import "wasi_snapshot_preview1" "path_open"
    (func (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (global (export "FFFUDE_VERSION_1_0") i32 (i32.const 0))
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32) (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32))
)
"#;

const SOCKET: &str = r#"
(module
  (import "wasi_snapshot_preview1" "sock_accept"
    (func (param i32 i32 i32) (result i32)))
  (memory (export "memory") 1)
  (global (export "FFFUDE_VERSION_1_0") i32 (i32.const 0))
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32) (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32))
)
"#;

const NO_ABI: &str = r#"
(module
  (memory (export "memory") 1)
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32) (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32))
)
"#;

const MAJOR_TWO: &str = r#"
(module
  (memory (export "memory") 1)
  (global (export "FFFUDE_VERSION_2_0") i32 (i32.const 0))
  (func (export "alloc") (param i32 i32) (result i32) (i32.const 64))
  (func (export "dealloc") (param i32 i32 i32))
  (func (export "buffer_drop") (param i32))
  (func (export "buffer_iterator_drop") (param i32))
  (func (export "decode_general_ffi") (param i32 i32 i32) (result i32) (i32.const 0))
  (func (export "buffer_iterator_next") (param i32 i32 i32))
)
"#;
