mod decode;

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

fn error_term<'a>(env: Env<'a>, message: &str) -> Term<'a> {
    (rustler::types::atom::error(), message.to_owned()).encode(env)
}

fn owned_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Binary<'a> {
    let mut owned = OwnedBinary::new(bytes.len()).expect("binary alloc");
    owned.as_mut_slice().copy_from_slice(bytes);
    Binary::from_owned(owned, env)
}

rustler::init!("Elixir.F3.Native");
