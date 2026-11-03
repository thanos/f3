#[rustler::nif]
fn nif_info() -> (String, String) {
    (
        "f3_native".to_owned(),
        env!("CARGO_PKG_VERSION").to_owned(),
    )
}

rustler::init!("Elixir.F3.Native");
