//! Dump footer metadata for the committed fixtures.
//!
//! `scripts/fixtures/dump_metadata.sh` copies this file into the pinned
//! upstream checkout and runs it as an `fff-poc` example. The JSON shape
//! matches `F3.Metadata.to_map/1`.

use std::fs;
use std::path::Path;

use arrow_ipc::convert::fb_to_schema;
use arrow_ipc::root_as_message;
use arrow_schema::{DataType, Field};
use fff_format::File::fff::flatbuf as fb;
use serde_json::{json, Value};

fn main() {
    let mut args = std::env::args().skip(1);
    let out_dir = args.next().expect("output directory");
    fs::create_dir_all(&out_dir).unwrap();

    for path in args {
        let value = dump(Path::new(&path));
        let stem = Path::new(&path)
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let text = serde_json::to_string_pretty(&value).unwrap() + "\n";
        fs::write(Path::new(&out_dir).join(format!("{stem}.json")), text).unwrap();
        println!("wrote {stem}.json");
    }
}

fn dump(path: &Path) -> Value {
    let bytes = fs::read(path).unwrap_or_else(|err| panic!("read {}: {err}", path.display()));
    let file_size = bytes.len();
    assert!(file_size >= 32, "{} is shorter than a postscript", path.display());
    let tail = &bytes[file_size - 32..];
    assert_eq!(&tail[30..32], b"F3", "magic");

    let metadata_size = u32_at(tail, 0) as usize;
    let footer_size = u32_at(tail, 4) as usize;
    let footer_compression = tail[8];
    let checksum_type = tail[9];
    let data_checksum = u64_at(tail, 10);
    let schema_checksum = u64_at(tail, 18);
    let major = u16_at(tail, 26);
    let minor = u16_at(tail, 28);

    let metadata_start = file_size - 32 - metadata_size;
    let footer = &bytes[file_size - 32 - footer_size..file_size - 32];
    let span = &bytes[metadata_start..file_size - 32];
    let footer_fb = fb::root_as_footer(footer).expect("footer");

    let schema = schema_fields(footer_fb.schema().expect("schema").bytes());
    let logical_tree = tree(footer_fb.logical_tree().expect("logical tree"));
    let row_groups = groups(&footer_fb, span, metadata_start);
    let encoding_versions = versions(&footer_fb);
    let optional_sections = sections(&footer_fb);
    let shared_dictionary = shared(&footer_fb);

    json!({
        "postscript": {
            "metadata_size": metadata_size,
            "footer_size": footer_size,
            "footer_compression": compression_name(footer_compression),
            "checksum_type": if checksum_type == 0 { "xxhash".to_string() } else { format!("unknown:{checksum_type}") },
            "data_checksum": data_checksum,
            "schema_checksum": schema_checksum,
            "major_version": major,
            "minor_version": minor
        },
        "schema": schema,
        "logical_tree": logical_tree,
        "encoding_versions": encoding_versions,
        "optional_sections": optional_sections,
        "shared_dictionary": shared_dictionary,
        "row_groups": row_groups
    })
}

fn groups(footer: &fb::Footer, span: &[u8], metadata_start: usize) -> Value {
    let row_groups = footer.row_groups().expect("row groups");
    let counts = row_groups.row_counts().expect("row counts");
    let offsets = row_groups.offsets().expect("offsets");
    let sizes = row_groups.sizes().expect("sizes");
    let metas = row_groups.row_group_metadatas().expect("row group metadata");
    assert_eq!(counts.len(), offsets.len());
    assert_eq!(counts.len(), sizes.len());
    assert_eq!(counts.len(), metas.len());

    let mut out = Vec::new();
    for index in 0..counts.len() {
        let meta = metas.get(index);
        let sections = meta.col_metadatas().expect("column metadata");
        let mut columns = Vec::new();
        for section_index in 0..sections.len() {
            let section = sections.get(section_index);
            let offset = section.offset() as usize;
            let size = section.size_() as usize;
            assert!(offset >= metadata_start, "column metadata before span");
            let local = offset - metadata_start;
            let bytes = &span[local..local + size];
            let column = flatbuffers::root::<fb::ColumnMetadata>(bytes).expect("column root");
            let chunks = column.column_chunks().map(chunk_list).unwrap_or_else(|| json!([]));
            columns.push(json!({"chunks": chunks}));
        }
        out.push(json!({
            "row_count": counts.get(index),
            "offset": offsets.get(index),
            "size": sizes.get(index),
            "columns": columns
        }));
    }
    Value::Array(out)
}

fn chunk_list(chunks: flatbuffers::Vector<flatbuffers::ForwardsUOffset<fb::Chunk>>) -> Value {
    let mut out = Vec::new();
    for index in 0..chunks.len() {
        out.push(chunk_json(&chunks.get(index)));
    }
    Value::Array(out)
}

fn chunk_json(chunk: &fb::Chunk) -> Value {
    let encunits = chunk
        .encunits()
        .map(|units| {
            let mut out = Vec::new();
            for index in 0..units.len() {
                out.push(encunit_json(&units.get(index)));
            }
            Value::Array(out)
        })
        .unwrap_or_else(|| json!([]));

    json!({
        "offset": chunk.offset(),
        "size": chunk.size_(),
        "num_rows": chunk.num_rows(),
        "checksum": chunk.checksum(),
        "dictionary": dictionary_json(chunk),
        "encunits": encunits
    })
}

fn dictionary_json(chunk: &fb::Chunk) -> Value {
    match chunk.encoding_type() {
        fb::DictionaryEncoding::NONE | fb::DictionaryEncoding::NoDictionary => {
            json!({"kind": "none"})
        }
        fb::DictionaryEncoding::LocalDictionary => {
            let indexes = chunk
                .encoding_as_local_dictionary()
                .and_then(|local| local.dictionary_encunit_idxs())
                .map(|ids| ids.iter().collect::<Vec<_>>())
                .unwrap_or_default();
            json!({"kind": "local", "encunit_indexes": indexes})
        }
        fb::DictionaryEncoding::SharedDictionary => {
            let index = chunk
                .encoding_as_shared_dictionary()
                .map(|shared| shared.shared_dictionary_idx())
                .unwrap_or(0);
            json!({"kind": "shared", "index": index})
        }
        other => json!({"kind": format!("unknown:{}", other.0)}),
    }
}

fn encunit_json(unit: &fb::EncUnit) -> Value {
    let (encoding, wasm_id) = match unit.encoding() {
        None => ("cascade".to_string(), Value::Null),
        Some(encoding) => {
            let wasm_id = encoding
                .wasm_encoding()
                .map(|wasm| Value::from(wasm.wasm_id()))
                .unwrap_or(Value::Null);
            (encoding_name(encoding.type_().0), wasm_id)
        }
    };

    json!({
        "size": unit.size_(),
        "num_rows": unit.num_rows(),
        "encoding": encoding,
        "compression": compression_name(unit.compression().0),
        "wasm_id": wasm_id
    })
}

fn versions(footer: &fb::Footer) -> Value {
    let Some(versions) = footer.encoding_versions() else {
        return json!([]);
    };
    let mut out = Vec::new();
    for index in 0..versions.len() {
        let version = versions.get(index);
        let semver = version.version();
        out.push(json!({
            "encoding": encoding_name(version.encoding_type().0),
            "version": format!("{}.{}.{}", semver.major(), semver.minor(), semver.patch())
        }));
    }
    Value::Array(out)
}

fn sections(footer: &fb::Footer) -> Value {
    let Some(sections) = footer.optional_sections() else {
        return json!([]);
    };
    let names = sections.names().expect("section names");
    let offsets = sections.offsets().expect("section offsets");
    let sizes = sections.sizes().expect("section sizes");
    let compressions = sections.compression_types().expect("section compression");
    assert_eq!(names.len(), offsets.len());
    assert_eq!(names.len(), sizes.len());
    assert_eq!(names.len(), compressions.len());
    let mut out = Vec::new();
    for index in 0..names.len() {
        out.push(json!({
            "name": names.get(index),
            "offset": offsets.get(index),
            "size": sizes.get(index),
            "compression": compression_name(compressions.get(index).0)
        }));
    }
    Value::Array(out)
}

fn shared(footer: &fb::Footer) -> Value {
    let Some(table) = footer.shared_dictionary_table() else {
        return Value::Null;
    };
    let chunks = table
        .dictionary_chunks()
        .map(chunk_list)
        .unwrap_or_else(|| json!([]));
    let positions = table
        .dictionary_positions()
        .map(|positions| {
            let mut out = Vec::new();
            for index in 0..positions.len() {
                let ids = positions
                    .get(index)
                    .chunk_ids()
                    .map(|ids| ids.iter().collect::<Vec<_>>())
                    .unwrap_or_default();
                out.push(Value::Array(ids.into_iter().map(Value::from).collect()));
            }
            Value::Array(out)
        })
        .unwrap_or_else(|| json!([]));
    let schema_bytes = table
        .dictionary_schema()
        .map(|bytes| bytes.bytes().to_vec())
        .unwrap_or_default();
    let schema = if schema_bytes.is_empty() {
        Value::Null
    } else {
        Value::Array(schema_fields(&schema_bytes))
    };
    json!({
        "chunks": chunks,
        "positions": positions,
        "schema": schema,
        "schema_bytes": schema_bytes.len()
    })
}

fn tree(node: fb::LogicalTree) -> Value {
    let children = node
        .children()
        .map(|children| {
            let mut out = Vec::new();
            for index in 0..children.len() {
                out.push(tree(children.get(index)));
            }
            out
        })
        .unwrap_or_default();
    json!({
        "id": logical_name(node.id().0),
        "children": children
    })
}

fn schema_fields(bytes: &[u8]) -> Vec<Value> {
    let message = root_as_message(bytes).expect("arrow message");
    let header = message.header_as_schema().expect("arrow schema");
    let schema = fb_to_schema(header);
    schema.fields().iter().map(|field| field_json(field.as_ref())).collect()
}

fn field_json(field: &Field) -> Value {
    json!({
        "name": field.name(),
        "nullable": field.is_nullable(),
        "type": type_json(field.data_type())
    })
}

fn type_json(data_type: &DataType) -> Value {
    match data_type {
        DataType::Null => json!("null"),
        DataType::Boolean => json!("bool"),
        DataType::Utf8 => json!("utf8"),
        DataType::Binary => json!("binary"),
        DataType::Int8 => json!("int8"),
        DataType::Int16 => json!("int16"),
        DataType::Int32 => json!("int32"),
        DataType::Int64 => json!("int64"),
        DataType::UInt8 => json!("uint8"),
        DataType::UInt16 => json!("uint16"),
        DataType::UInt32 => json!("uint32"),
        DataType::UInt64 => json!("uint64"),
        DataType::Float16 => json!("float16"),
        DataType::Float32 => json!("float32"),
        DataType::Float64 => json!("float64"),
        DataType::List(field) | DataType::LargeList(field) => {
            json!({"list": field_json(field.as_ref())})
        }
        DataType::Struct(fields) => {
            json!({"struct": fields.iter().map(|field| field_json(field.as_ref())).collect::<Vec<_>>()})
        }
        other => json!({"unsupported": format!("{other:?}")}),
    }
}

fn encoding_name(byte: u8) -> String {
    match byte {
        0 => "cascade".to_string(),
        255 => "custom_wasm".to_string(),
        other => other.to_string(),
    }
}

fn compression_name(byte: u8) -> String {
    match byte {
        0 => "uncompressed".to_string(),
        1 => "zstd".to_string(),
        2 => "lz4".to_string(),
        other => other.to_string(),
    }
}

fn logical_name(byte: u8) -> String {
    match byte {
        0 => "flat".to_string(),
        1 => "list".to_string(),
        2 => "struct".to_string(),
        3 => "list_of_struct_of_primitive".to_string(),
        other => other.to_string(),
    }
}

fn u16_at(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes(bytes[offset..offset + 2].try_into().unwrap())
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap())
}

fn u64_at(bytes: &[u8], offset: usize) -> u64 {
    u64::from_le_bytes(bytes[offset..offset + 8].try_into().unwrap())
}
