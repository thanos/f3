use std::any::Any;
use std::fs::{self, File};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use arrow_array::builder::{Int32Builder, ListBuilder};
use arrow_array::{ArrayRef, Float64Array, Int32Array, Int64Array, RecordBatch, StringArray, StructArray};
use arrow_schema::{DataType, Field, Schema, SchemaRef};
use fff_format::File::fff::flatbuf::CompressionType;
use fff_poc::options::{DictionaryTypeOptions, FileWriterOptions, FileWriterOptionsBuilder};
use fff_poc::writer::FileWriter;

const UPSTREAM_SHA: &str = "bd92506447dc1333820cfe9a34ebbf497fe0219e";

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let upstream = PathBuf::from(required(&args, "--upstream"));
    let out = PathBuf::from(required(&args, "--out"));
    let wasm_log = PathBuf::from(required(&args, "--wasm-log"));
    fs::create_dir_all(&out).expect("create fixture directory");

    let mut fixtures = Vec::new();
    let mut skipped = Vec::new();

    run(&out, "small.f3", &mut fixtures, &mut skipped, || small(&out));
    run(&out, "nullable.f3", &mut fixtures, &mut skipped, || nullable(&out));
    run(&out, "wide.f3", &mut fixtures, &mut skipped, || wide(&out));
    run(&out, "multi_row_group.f3", &mut fixtures, &mut skipped, || {
        multi_row_group(&out)
    });
    run(&out, "compressed_zstd.f3", &mut fixtures, &mut skipped, || {
        compressed(&out, "compressed_zstd.f3", "zstd", CompressionType::Zstd)
    });
    run(&out, "compressed_lz4.f3", &mut fixtures, &mut skipped, || {
        compressed(&out, "compressed_lz4.f3", "lz4", CompressionType::Lz4)
    });
    run(&out, "dictionary.f3", &mut fixtures, &mut skipped, || {
        dictionary(&out)
    });
    run(&out, "nested.f3", &mut fixtures, &mut skipped, || nested(&out));
    run(&out, "custom_wasm.f3", &mut fixtures, &mut skipped, || {
        custom_wasm(&out, &upstream, &wasm_log)
    });

    let intent = J::obj(vec![
        ("upstream_sha", J::str(UPSTREAM_SHA)),
        ("generator", J::str("scripts/fixtures/generate.sh")),
        (
            "generator_crate",
            J::str("scripts/fixtures/generator"),
        ),
        ("fixtures", J::Arr(fixtures)),
        ("skipped", J::Arr(skipped)),
    ]);
    let path = out.join("intent.json");
    fs::write(&path, intent.to_string()).expect("write intent.json");
    println!("wrote {}", path.display());
}

fn run(
    out: &Path,
    name: &str,
    fixtures: &mut Vec<J>,
    skipped: &mut Vec<J>,
    body: impl FnOnce() -> Result<J, String>,
) {
    let path = out.join(name);
    let outcome = catch_unwind(AssertUnwindSafe(body));
    match outcome {
        Ok(Ok(fixture)) => fixtures.push(fixture),
        Ok(Err(reason)) => {
            let _ = fs::remove_file(&path);
            skipped.push(skip(name, &reason));
            eprintln!("skipped {name}: {reason}");
        }
        Err(payload) => {
            let _ = fs::remove_file(&path);
            let reason = panic_message(payload);
            skipped.push(skip(name, &reason));
            eprintln!("skipped {name}: panicked: {reason}");
        }
    }
}

fn skip(name: &str, reason: &str) -> J {
    J::obj(vec![
        ("name", J::str(name)),
        ("reason", J::str(reason)),
    ])
}

fn small(out: &Path) -> Result<J, String> {
    let schema = schema(&[
        ("trade_id", DataType::Int64, false),
        ("symbol", DataType::Utf8, false),
        ("price", DataType::Float64, false),
    ]);
    let batch = record(
        &schema,
        vec![
            Arc::new(Int64Array::from(vec![1_i64, 2, 3])),
            Arc::new(StringArray::from(vec!["AAPL", "MSFT", "GOOG"])),
            Arc::new(Float64Array::from(vec![123.5_f64, 234.0, 345.25])),
        ],
    )?;
    write_batches(&out.join("small.f3"), &[batch], defaults().build())?;
    Ok(fixture(
        "small.f3",
        schema_desc(&[
            ("trade_id", "int64", false),
            ("symbol", "utf8", false),
            ("price", "float64", false),
        ]),
        vec![
            row(vec![J::int(1), J::str("AAPL"), J::float(123.5)]),
            row(vec![J::int(2), J::str("MSFT"), J::float(234.0)]),
            row(vec![J::int(3), J::str("GOOG"), J::float(345.25)]),
        ],
        vec![
            ("compression", J::str("uncompressed")),
            ("dictionary", J::str("EncoderDictionary")),
            ("row_groups", J::str("one batch, default row group size")),
            ("wasm", J::str("none")),
        ],
        "Three non-null rows. One write_batch call.",
    ))
}

fn nullable(out: &Path) -> Result<J, String> {
    let schema = schema(&[
        ("trade_id", DataType::Int64, true),
        ("symbol", DataType::Utf8, true),
        ("price", DataType::Float64, true),
    ]);
    let batch = record(
        &schema,
        vec![
            Arc::new(Int64Array::from(vec![Some(1_i64), None, Some(3)])),
            Arc::new(StringArray::from(vec![Some("AAPL"), None, Some("GOOG")])),
            Arc::new(Float64Array::from(vec![Some(123.5_f64), Some(234.0), None])),
        ],
    )?;
    write_batches(&out.join("nullable.f3"), &[batch], defaults().build())?;
    Ok(fixture(
        "nullable.f3",
        schema_desc(&[
            ("trade_id", "int64", true),
            ("symbol", "utf8", true),
            ("price", "float64", true),
        ]),
        vec![
            row(vec![J::int(1), J::str("AAPL"), J::float(123.5)]),
            row(vec![J::Null, J::Null, J::float(234.0)]),
            row(vec![J::int(3), J::str("GOOG"), J::Null]),
        ],
        vec![
            ("compression", J::str("uncompressed")),
            ("dictionary", J::str("EncoderDictionary")),
            ("row_groups", J::str("one batch, default row group size")),
            ("wasm", J::str("none")),
        ],
        "Each column contains one null.",
    ))
}

fn wide(out: &Path) -> Result<J, String> {
    let mut fields = Vec::new();
    let mut desc = Vec::new();
    let mut columns: Vec<ArrayRef> = Vec::new();
    let mut row0 = Vec::new();
    let mut row1 = Vec::new();
    for index in 0..16 {
        let name = format!("col_{index:02}");
        fields.push(Field::new(&name, DataType::Int64, false));
        desc.push((name, "int64".to_owned(), false));
        columns.push(Arc::new(Int64Array::from(vec![index as i64, 100 + index as i64])));
        row0.push(J::int(index as i64));
        row1.push(J::int(100 + index as i64));
    }
    let schema = Arc::new(Schema::new(fields));
    let batch = record(&schema, columns)?;
    write_batches(&out.join("wide.f3"), &[batch], defaults().build())?;
    Ok(fixture(
        "wide.f3",
        desc,
        vec![row(row0), row(row1)],
        vec![
            ("compression", J::str("uncompressed")),
            ("dictionary", J::str("EncoderDictionary")),
            ("column_count", J::int(16)),
            ("wasm", J::str("none")),
        ],
        "Sixteen int64 columns, two rows.",
    ))
}

fn multi_row_group(out: &Path) -> Result<J, String> {
    let schema = schema(&[("trade_id", DataType::Int64, false)]);
    let first = record(&schema, vec![Arc::new(Int64Array::from(vec![1_i64, 2]))])?;
    let second = record(&schema, vec![Arc::new(Int64Array::from(vec![3_i64]))])?;
    let options = defaults().set_row_group_size(2).build();
    write_batches(&out.join("multi_row_group.f3"), &[first, second], options)?;
    Ok(fixture(
        "multi_row_group.f3",
        schema_desc(&[("trade_id", "int64", false)]),
        vec![row(vec![J::int(1)]), row(vec![J::int(2)]), row(vec![J::int(3)])],
        vec![
            ("compression", J::str("uncompressed")),
            ("dictionary", J::str("EncoderDictionary")),
            ("row_group_size", J::int(2)),
            ("write_batches", J::int(2)),
            ("wasm", J::str("none")),
        ],
        "First batch has 2 rows and meets row_group_size inside write_batch. Second batch has 1 row and is closed by finish.",
    ))
}

fn compressed(
    out: &Path,
    name: &str,
    label: &str,
    compression: CompressionType,
) -> Result<J, String> {
    let schema = schema(&[("value", DataType::Int64, false)]);
    let values = vec![1_i64, 1, 1, 1, 2, 2, 2, 2];
    let batch = record(&schema, vec![Arc::new(Int64Array::from(values.clone()))])?;
    let options = defaults().set_compression_type(compression).build();
    write_batches(&out.join(name), &[batch], options)?;
    Ok(fixture(
        name,
        schema_desc(&[("value", "int64", false)]),
        values.into_iter().map(|value| row(vec![J::int(value)])).collect(),
        vec![
            ("compression", J::str(label)),
            ("dictionary", J::str("EncoderDictionary")),
            ("wasm", J::str("none")),
        ],
        "Repeated int64 values so the encoder has a compressible column.",
    ))
}

fn dictionary(out: &Path) -> Result<J, String> {
    let path = out.join("dictionary.f3");
    match write_dictionary(&path, DictionaryTypeOptions::LocalDictionary) {
        Ok(()) => Ok(dictionary_fixture(
            "LocalDictionary",
            "FileWriterOptions dictionary_type LocalDictionary.",
        )),
        Err(local_error) => {
            let _ = fs::remove_file(&path);
            match write_dictionary(&path, DictionaryTypeOptions::EncoderDictionary) {
                Ok(()) => Ok(dictionary_fixture(
                    "EncoderDictionary",
                    &format!(
                        "LocalDictionary failed ({local_error}). Fell back to EncoderDictionary, the writer default."
                    ),
                )),
                Err(encoder_error) => Err(format!(
                    "LocalDictionary: {local_error}; EncoderDictionary: {encoder_error}"
                )),
            }
        }
    }
}

fn write_dictionary(path: &Path, dictionary: DictionaryTypeOptions) -> Result<(), String> {
    let schema = schema(&[
        ("trade_id", DataType::Int64, false),
        ("symbol", DataType::Utf8, false),
    ]);
    let batch = record(
        &schema,
        vec![
            Arc::new(Int64Array::from(vec![1_i64, 2, 3, 4])),
            Arc::new(StringArray::from(vec!["AAPL", "AAPL", "MSFT", "AAPL"])),
        ],
    )?;
    let options = defaults().set_dictionary_type(dictionary).build();
    write_batches(path, &[batch], options)
}

fn dictionary_fixture(dictionary: &str, notes: &str) -> J {
    fixture(
        "dictionary.f3",
        schema_desc(&[("trade_id", "int64", false), ("symbol", "utf8", false)]),
        vec![
            row(vec![J::int(1), J::str("AAPL")]),
            row(vec![J::int(2), J::str("AAPL")]),
            row(vec![J::int(3), J::str("MSFT")]),
            row(vec![J::int(4), J::str("AAPL")]),
        ],
        vec![
            ("compression", J::str("uncompressed")),
            ("dictionary", J::str(dictionary)),
            ("wasm", J::str("none")),
        ],
        notes,
    )
}

fn nested(out: &Path) -> Result<J, String> {
    let path = out.join("nested.f3");
    match write_nested(&path) {
        Ok(()) => Ok(nested_fixture(
            "struct and list<int32>",
            "One nullable struct column and one list<int32> column.",
        )),
        Err(combined) => {
            let _ = fs::remove_file(&path);
            match write_struct_only(&path) {
                Ok(()) => Ok(nested_fixture(
                    "struct",
                    &format!("Combined struct+list failed ({combined}). Kept a struct-only file."),
                )),
                Err(struct_only) => Err(format!(
                    "struct+list: {combined}; struct only: {struct_only}"
                )),
            }
        }
    }
}

fn write_nested(path: &Path) -> Result<(), String> {
    let (struct_field, struct_array) = trade_struct();
    let (list_field, list_array) = tag_list();
    let schema = Arc::new(Schema::new(vec![struct_field, list_field]));
    let batch = record(&schema, vec![struct_array, list_array])?;
    write_batches(path, &[batch], defaults().build())
}

fn write_struct_only(path: &Path) -> Result<(), String> {
    let (struct_field, struct_array) = trade_struct();
    let schema = Arc::new(Schema::new(vec![struct_field]));
    let batch = record(&schema, vec![struct_array])?;
    write_batches(path, &[batch], defaults().build())
}

fn nested_fixture(shape: &str, notes: &str) -> J {
    let rows = if shape.contains("list") {
        vec![
            row(vec![
                J::obj(vec![
                    ("b", J::int(1)),
                    ("c", J::str("a")),
                ]),
                J::arr(vec![J::int(1), J::int(2)]),
            ]),
            row(vec![
                J::obj(vec![("b", J::int(2)), ("c", J::str("b"))]),
                J::arr(vec![J::int(3)]),
            ]),
            row(vec![
                J::obj(vec![("b", J::Null), ("c", J::Null)]),
                J::arr(vec![]),
            ]),
            row(vec![
                J::obj(vec![("b", J::int(4)), ("c", J::str("d"))]),
                J::arr(vec![J::int(4)]),
            ]),
        ]
    } else {
        vec![
            row(vec![J::obj(vec![("b", J::int(1)), ("c", J::str("a"))])]),
            row(vec![J::obj(vec![("b", J::int(2)), ("c", J::str("b"))])]),
            row(vec![J::obj(vec![("b", J::Null), ("c", J::Null)])]),
            row(vec![J::obj(vec![("b", J::int(4)), ("c", J::str("d"))])]),
        ]
    };
    let schema = if shape.contains("list") {
        schema_desc(&[
            ("trade", "struct{b:int32, c:utf8}", true),
            ("nums", "list<int32>", false),
        ])
    } else {
        schema_desc(&[("trade", "struct{b:int32, c:utf8}", true)])
    };
    fixture(
        "nested.f3",
        schema,
        rows,
        vec![
            ("compression", J::str("uncompressed")),
            ("dictionary", J::str("EncoderDictionary")),
            ("shape", J::str(shape)),
            ("wasm", J::str("none")),
        ],
        notes,
    )
}

fn trade_struct() -> (Field, ArrayRef) {
    let b_field = Arc::new(Field::new("b", DataType::Int32, true));
    let c_field = Arc::new(Field::new("c", DataType::Utf8, true));
    let b = Arc::new(Int32Array::from(vec![Some(1), Some(2), None, Some(4)])) as ArrayRef;
    let c = Arc::new(StringArray::from(vec![
        Some("a"),
        Some("b"),
        None,
        Some("d"),
    ])) as ArrayRef;
    let array = StructArray::from(vec![(Arc::clone(&b_field), b), (Arc::clone(&c_field), c)]);
    let field = Field::new(
        "trade",
        DataType::Struct(vec![b_field, c_field].into()),
        true,
    );
    (field, Arc::new(array))
}

fn tag_list() -> (Field, ArrayRef) {
    let mut builder = ListBuilder::new(Int32Builder::new());
    for row in [vec![1, 2], vec![3], vec![], vec![4]] {
        for value in row {
            builder.values().append_value(value);
        }
        builder.append(true);
    }
    let array = Arc::new(builder.finish()) as ArrayRef;
    let field = Field::new(
        "nums",
        DataType::List(Arc::new(Field::new("item", DataType::Int32, true))),
        false,
    );
    (field, array)
}

fn custom_wasm(out: &Path, upstream: &Path, wasm_log: &Path) -> Result<J, String> {
    let artifact = upstream.join("target/wasm32-wasip1/opt-size-lvl3/fff_ude_example_fff.wasm");
    if !artifact.is_file() {
        return Err(format!(
            "built-in wasm artifact is missing. FileWriterOptions::write_built_in_wasm reads fff-test-util BUILTIN_WASM_PATH, which is target/wasm32-wasip1/opt-size-lvl3/fff_ude_example_fff.wasm under the upstream checkout. The wasm32-wasip1 build of fff-ude-example-fff failed while compiling zstd-sys. Distinct clang errors:\n{}",
            distinct_errors(wasm_log)
        ));
    }
    let schema = schema(&[("trade_id", DataType::Int64, false)]);
    let batch = record(&schema, vec![Arc::new(Int64Array::from(vec![1_i64, 2, 3]))])?;
    let options = defaults().write_built_in_wasm(true).build();
    write_batches(&out.join("custom_wasm.f3"), &[batch], options)?;
    Ok(fixture(
        "custom_wasm.f3",
        schema_desc(&[("trade_id", "int64", false)]),
        vec![row(vec![J::int(1)]), row(vec![J::int(2)]), row(vec![J::int(3)])],
        vec![
            ("compression", J::str("uncompressed")),
            ("dictionary", J::str("EncoderDictionary")),
            ("wasm", J::str("write_built_in_wasm")),
        ],
        "Uses FileWriterOptions::write_built_in_wasm. Upstream labels those encodings CUSTOM_WASM and embeds target/wasm32-wasip1/opt-size-lvl3/fff_ude_example_fff.wasm. This is the upstream built-in Wasm decoder, not a separately authored encoder.",
    ))
}

fn defaults() -> FileWriterOptionsBuilder {
    FileWriterOptionsBuilder::with_defaults()
}

fn schema(fields: &[(&str, DataType, bool)]) -> SchemaRef {
    Arc::new(Schema::new(
        fields
            .iter()
            .map(|(name, data_type, nullable)| Field::new(*name, data_type.clone(), *nullable))
            .collect::<Vec<_>>(),
    ))
}

fn record(schema: &SchemaRef, columns: Vec<ArrayRef>) -> Result<RecordBatch, String> {
    RecordBatch::try_new(Arc::clone(schema), columns).map_err(|error| error.to_string())
}

fn write_batches(
    path: &Path,
    batches: &[RecordBatch],
    options: FileWriterOptions,
) -> Result<(), String> {
    if batches.is_empty() {
        return Err("no batches".to_owned());
    }
    let file = File::create(path).map_err(|error| error.to_string())?;
    let mut writer = FileWriter::try_new(batches[0].schema(), file, options)
        .map_err(|error| format!("{error:?}"))?;
    for batch in batches {
        writer
            .write_batch(batch)
            .map_err(|error| format!("{error:?}"))?;
    }
    writer.finish().map_err(|error| format!("{error:?}"))?;
    let bytes = fs::read(path).map_err(|error| error.to_string())?;
    if bytes.len() < 32 || &bytes[bytes.len() - 2..] != b"F3" {
        return Err("finished file does not end with the F3 magic".to_owned());
    }
    Ok(())
}

fn schema_desc(fields: &[(&str, &str, bool)]) -> Vec<(String, String, bool)> {
    fields
        .iter()
        .map(|(name, type_name, nullable)| ((*name).to_owned(), (*type_name).to_owned(), *nullable))
        .collect()
}

fn fixture(
    name: &str,
    schema: Vec<(String, String, bool)>,
    rows: Vec<J>,
    options: Vec<(&str, J)>,
    notes: &str,
) -> J {
    let schema = schema
        .iter()
        .map(|(name, type_name, nullable)| {
            J::obj(vec![
                ("name", J::str(name)),
                ("type", J::str(type_name)),
                ("nullable", J::Bool(*nullable)),
            ])
        })
        .collect();
    let options = options
        .into_iter()
        .map(|(key, value)| (key.to_owned(), value))
        .collect();
    J::obj(vec![
        ("name", J::str(name)),
        ("schema", J::Arr(schema)),
        ("rows", J::Arr(rows)),
        ("options", J::Obj(options)),
        ("notes", J::str(notes)),
    ])
}

fn row(values: Vec<J>) -> J {
    J::Arr(values)
}

fn required(args: &[String], flag: &str) -> String {
    args.windows(2)
        .find(|pair| pair[0] == flag)
        .map(|pair| pair[1].clone())
        .unwrap_or_else(|| panic!("missing {flag}"))
}

fn panic_message(payload: Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_owned()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "writer panicked with a non-string payload".to_owned()
    }
}

fn distinct_errors(path: &Path) -> String {
    let Ok(text) = fs::read_to_string(path) else {
        return format!("wasm build log is not readable at {}", path.display());
    };
    let mut found = Vec::new();
    for line in text.lines() {
        let snippet = if let Some(index) = line.find("fatal error:") {
            Some(line[index..].trim().to_owned())
        } else if let Some(index) = line.find("error: unknown target triple") {
            Some(line[index..].trim().to_owned())
        } else {
            None
        };
        if let Some(snippet) = snippet {
            if !found.iter().any(|seen: &String| seen == &snippet) {
                found.push(snippet);
            }
        }
        if found.len() == 4 {
            break;
        }
    }
    if found.is_empty() {
        "no distinct clang error in the wasm build log".to_owned()
    } else {
        found.join("\n")
    }
}

enum J {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    Str(String),
    Arr(Vec<J>),
    Obj(Vec<(String, J)>),
}

impl J {
    fn str(value: impl Into<String>) -> Self {
        J::Str(value.into())
    }

    fn int(value: i64) -> Self {
        J::Int(value)
    }

    fn float(value: f64) -> Self {
        J::Float(value)
    }

    fn obj(fields: Vec<(&str, J)>) -> Self {
        J::Obj(
            fields
                .into_iter()
                .map(|(key, value)| (key.to_owned(), value))
                .collect(),
        )
    }

    fn arr(values: Vec<J>) -> Self {
        J::Arr(values)
    }
}

impl std::fmt::Display for J {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            J::Null => formatter.write_str("null"),
            J::Bool(value) => write!(formatter, "{value}"),
            J::Int(value) => write!(formatter, "{value}"),
            J::Float(value) => write!(formatter, "{value}"),
            J::Str(value) => write!(formatter, "\"{}\"", escape(value)),
            J::Arr(values) => {
                formatter.write_str("[")?;
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        formatter.write_str(",")?;
                    }
                    write!(formatter, "{value}")?;
                }
                formatter.write_str("]")
            }
            J::Obj(fields) => {
                formatter.write_str("{")?;
                for (index, (key, value)) in fields.iter().enumerate() {
                    if index > 0 {
                        formatter.write_str(",")?;
                    }
                    write!(formatter, "\"{}\":{value}", escape(key))?;
                }
                formatter.write_str("}")
            }
        }
    }
}

fn escape(value: &str) -> String {
    let mut escaped = String::new();
    for character in value.chars() {
        match character {
            '"' => escaped.push_str("\\\""),
            '\\' => escaped.push_str("\\\\"),
            '\n' => escaped.push_str("\\n"),
            '\r' => escaped.push_str("\\r"),
            '\t' => escaped.push_str("\\t"),
            other if other.is_control() => escaped.push_str(&format!("\\u{:04x}", other as u32)),
            other => escaped.push(other),
        }
    }
    escaped
}
