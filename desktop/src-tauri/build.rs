fn main() {
    // The one schema every Bridg app speaks; never keep a copy here.
    std::env::set_var("PROTOC", protoc_bin_vendored::protoc_bin_path().expect("vendored protoc"));
    prost_build::compile_protos(&["../../proto/bridg.proto"], &["../../proto"]).expect("compile bridg.proto");
    println!("cargo:rerun-if-changed=../../proto/bridg.proto");
    tauri_build::build();
}
