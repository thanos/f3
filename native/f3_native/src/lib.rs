mod decode;
mod wasm;

use std::panic::{catch_unwind, AssertUnwindSafe};

use decode::{decode_owned, Compression, OwnedCol, Requested, Values};
use rustler::{Atom, Binary, Encoder, Env, OwnedBinary, Term};

rustler::atoms! {
    uncompressed,
    zstd,
    lz4,
    list32,
    list64,
    i64,
    i32,
    u64,
    u32,
    f64,
    f32,
    bool_atom = "bool",
    utf8,
    integer,
    u8_atom = "u8",
    u16_atom = "u16",
}

#[rustler::nif]
fn nif_info() -> (String, String) {
    (
        "f3_native".to_owned(),
        env!("CARGO_PKG_VERSION").to_owned(),
    )
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_encunit<'a>(env: Env<'a>, payload: Binary, compression: Atom, arrow_type: Atom) -> Term<'a> {
    let parsed = match (compression_of(compression), request_of(arrow_type)) {
        (Ok(compression), Ok(request)) => (compression, request),
        (Err(message), _) | (_, Err(message)) => return error_term(env, &message),
    };
    let bytes = payload.as_slice().to_vec();
    let decoded = catch_unwind(AssertUnwindSafe(|| decode_owned(bytes, parsed.0, parsed.1)));
    match decoded {
        Ok(Ok(column)) => ok_term(env, column),
        Ok(Err(message)) => error_term(env, &message),
        Err(_) => error_term(env, "panic"),
    }
}

fn compression_of(atom: Atom) -> Result<Compression, String> {
    if atom == uncompressed() {
        Ok(Compression::None)
    } else if atom == zstd() {
        Ok(Compression::Zstd)
    } else if atom == lz4() {
        Ok(Compression::Lz4)
    } else {
        Err("unknown compression".to_string())
    }
}

fn request_of(atom: Atom) -> Result<Requested, String> {
    if atom == list32() || atom == list64() {
        Ok(Requested::List)
    } else if atom == i64()
        || atom == i32()
        || atom == u64()
        || atom == u32()
        || atom == f64()
        || atom == f32()
        || atom == bool_atom()
        || atom == utf8()
        || atom == integer()
        || atom == u8_atom()
        || atom == u16_atom()
    {
        Ok(Requested::Primitive)
    } else {
        Err("unknown arrow type".to_string())
    }
}

fn ok_term(env: Env<'_>, column: OwnedCol) -> Term<'_> {
    let kind = Atom::from_str(env, column.kind).expect("kind atom");
    let values = match column.values {
        Values::Bytes(bytes) => owned_binary(env, &bytes).encode(env),
        Values::Utf8(values) => values.encode(env),
    };
    let validity = match column.validity {
        Some(bytes) => owned_binary(env, &bytes).encode(env),
        None => rustler::types::atom::nil().encode(env),
    };
    (
        rustler::types::atom::ok(),
        (kind, column.rows, values, validity),
    )
        .encode(env)
}

#[rustler::nif(schedule = "DirtyCpu")]
fn decode_wasm<'a>(
    env: Env<'a>,
    module: Binary,
    payload: Binary,
    compression: Atom,
    arrow_type: Atom,
    rows: u32,
) -> Term<'a> {
    let parsed = match compression_of(compression) {
        Ok(compression) => compression,
        Err(message) => return error_term(env, &message),
    };
    let kind = match arrow_type_name(arrow_type) {
        Some(kind) => kind,
        None => return error_term(env, "unknown arrow type"),
    };
    let module = module.as_slice().to_vec();
    let payload = payload.as_slice().to_vec();
    let decoded = catch_unwind(AssertUnwindSafe(|| {
        wasm::decode(&module, payload, parsed, kind, rows as usize)
    }));
    match decoded {
        Ok(Ok(column)) => ok_term(env, column),
        Ok(Err(message)) => error_term(env, &message),
        Err(_) => error_term(env, "panic"),
    }
}

#[rustler::nif]
fn clear_wasm_cache() -> Atom {
    wasm::clear_cache();
    rustler::types::atom::ok()
}

#[rustler::nif]
fn invalidate_wasm(bytes: Binary) -> Atom {
    wasm::invalidate(bytes.as_slice());
    rustler::types::atom::ok()
}

#[rustler::nif]
fn wasm_sample<'a>(env: Env<'a>, name: String) -> Term<'a> {
    match wasm::sample(&name) {
        Ok(bytes) => (rustler::types::atom::ok(), owned_binary(env, &bytes)).encode(env),
        Err(message) => error_term(env, &message),
    }
}

fn arrow_type_name(atom: Atom) -> Option<&'static str> {
    if atom == i64() {
        Some("i64")
    } else if atom == i32() {
        Some("i32")
    } else if atom == u64() {
        Some("u64")
    } else if atom == u32() {
        Some("u32")
    } else if atom == f64() {
        Some("f64")
    } else if atom == f32() {
        Some("f32")
    } else if atom == bool_atom() {
        Some("bool")
    } else if atom == utf8() {
        Some("utf8")
    } else if atom == integer() {
        Some("integer")
    } else if atom == u8_atom() {
        Some("u8")
    } else if atom == u16_atom() {
        Some("u16")
    } else if atom == list32() {
        Some("list32")
    } else if atom == list64() {
        Some("list64")
    } else {
        None
    }
}

fn error_term<'a>(env: Env<'a>, message: &str) -> Term<'a> {
    (rustler::types::atom::error(), message.to_owned()).encode(env)
}

fn owned_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut owned = OwnedBinary::new(bytes.len()).expect("binary alloc");
    owned.as_mut_slice().copy_from_slice(bytes);
    Binary::from_owned(owned, env)
}

rustler::init!("Elixir.F3.Native");
