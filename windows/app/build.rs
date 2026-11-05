fn main() {
    // Icon, version information and manifest for the Windows executable.
    if std::env::var("CARGO_CFG_WINDOWS").is_ok() {
        embed_resource::compile("res/yasno.rc", embed_resource::NONE).manifest_optional().unwrap();
    }
}
