use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::process::Command;

// New untracked files can affect the compiled runtime only under these bounded
// source roots. Watching them catches file creation without recursively
// watching `.git`, the workspace `target` directory, or generated tool output.
const IDENTITY_SOURCE_ROOTS: &[&str] = &["crates", "vendor"];

fn main() {
    println!("cargo:rerun-if-env-changed=NUX_RUNTIME_BUILD_PROFILE");
    println!("cargo:rerun-if-env-changed=NUX_RUNTIME_SOURCE_REVISION");
    println!("cargo:rerun-if-env-changed=NUX_RUNTIME_UPDATE_HEADER");
    println!("cargo:rerun-if-changed=cbindgen.toml");
    println!("cargo:rerun-if-changed=src");

    let repo_root =
        git_repo_root().expect("nux-apple-runtime must be built from a verifiable Git worktree");
    emit_identity_rerun_inputs(&repo_root);
    let contract_fingerprint = verify_generated_header();
    let requested_revision = std::env::var("NUX_RUNTIME_SOURCE_REVISION")
        .ok()
        .filter(|value| !value.trim().is_empty());
    let revision = resolved_source_revision(&repo_root, requested_revision);
    let runtime_identity = format!("{}@{revision}", env!("CARGO_PKG_VERSION"));
    let rustc = command_output(
        std::env::var("RUSTC").unwrap_or_else(|_| "rustc".to_owned()),
        &["--version"],
    )
    .unwrap_or_else(|| "unknown".to_owned());
    let target = std::env::var("TARGET").unwrap_or_else(|_| "unknown".to_owned());
    let profile = std::env::var("NUX_RUNTIME_BUILD_PROFILE")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .or_else(|| std::env::var("PROFILE").ok())
        .unwrap_or_else(|| "unknown".to_owned());
    let features = if std::env::var_os("CARGO_FEATURE_APPLE_PRODUCT").is_some() {
        "apple-product"
    } else {
        "none"
    };
    let luaur_version = if std::env::var_os("CARGO_FEATURE_APPLE_PRODUCT").is_some() {
        "\"0.1.8\""
    } else {
        "null"
    };
    let provenance = format!(
        concat!(
            "{{\"schemaVersion\":2,\"runtimeVersion\":\"{}\",",
            "\"sourceRevision\":\"{}\",\"runtimeIdentity\":\"{}\",",
            "\"contractFingerprint\":\"{}\",\"target\":\"{}\",",
            "\"profile\":\"{}\",\"rustc\":\"{}\",",
            "\"features\":\"{}\",\"wgpuVersion\":\"30.0.0\",",
            "\"luaurVersion\":{}}}"
        ),
        env!("CARGO_PKG_VERSION"),
        json_escape(&revision),
        json_escape(&runtime_identity),
        contract_fingerprint,
        json_escape(&target),
        json_escape(&profile),
        json_escape(&rustc),
        features,
        luaur_version,
    );
    println!("cargo:rustc-env=NUX_RUNTIME_SOURCE_REVISION={revision}");
    println!("cargo:rustc-env=NUX_RUNTIME_BUILD_PROVENANCE={provenance}");
}

fn git_repo_root() -> Option<PathBuf> {
    let crate_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR")?);
    let crate_dir = crate_dir.to_str()?;
    command_output(
        "git".to_owned(),
        &["-C", crate_dir, "rev-parse", "--show-toplevel"],
    )
    .map(PathBuf::from)
}

fn emit_identity_rerun_inputs(repo_root: &std::path::Path) {
    let repo_root_text = repo_root
        .to_str()
        .expect("runtime repository path must be UTF-8");
    let tracked_paths = command_bytes("git", &["-C", repo_root_text, "ls-files", "--cached", "-z"])
        .expect("cannot enumerate runtime identity source inputs");
    let untracked_source_paths = command_bytes(
        "git",
        &[
            "-C",
            repo_root_text,
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            "crates",
            "vendor",
        ],
    )
    .expect("cannot enumerate untracked runtime identity source inputs");
    for source_path in tracked_paths
        .split(|byte| *byte == 0)
        .chain(untracked_source_paths.split(|byte| *byte == 0))
        .filter(|path| !path.is_empty())
    {
        let source_path =
            std::str::from_utf8(source_path).expect("runtime source path must be UTF-8");
        let source_path = repo_root.join(source_path);
        if !source_path.exists() {
            continue;
        }
        println!("cargo:rerun-if-changed={}", source_path.display());
    }

    for source_root in IDENTITY_SOURCE_ROOTS {
        let source_root = repo_root.join(source_root);
        if source_root.is_dir() {
            println!("cargo:rerun-if-changed={}", source_root.display());
        }
    }

    for git_path in ["HEAD", "index", "packed-refs"] {
        if let Some(path) = command_output(
            "git".to_owned(),
            &["-C", repo_root_text, "rev-parse", "--git-path", git_path],
        ) {
            emit_git_rerun_path(repo_root, &path);
        }
    }
    if let Some(symbolic_head) = command_output(
        "git".to_owned(),
        &["-C", repo_root_text, "symbolic-ref", "-q", "HEAD"],
    ) && let Some(path) = command_output(
        "git".to_owned(),
        &[
            "-C",
            repo_root_text,
            "rev-parse",
            "--git-path",
            &symbolic_head,
        ],
    ) {
        emit_git_rerun_path(repo_root, &path);
    }
}

fn emit_git_rerun_path(repo_root: &std::path::Path, path: &str) {
    let path = PathBuf::from(path);
    let path = if path.is_absolute() {
        path
    } else {
        repo_root.join(path)
    };
    println!("cargo:rerun-if-changed={}", path.display());
}

fn git_revision(repo_root: &std::path::Path) -> Option<String> {
    let repo_root = repo_root.to_str()?;
    let head = command_output(
        "git".to_owned(),
        &["-C", repo_root, "rev-parse", "--verify", "HEAD"],
    )?;
    let tracked_diff = command_bytes(
        "git",
        &[
            "-C",
            repo_root,
            "diff",
            "--binary",
            "--no-ext-diff",
            "HEAD",
            "--",
        ],
    )?;
    let untracked = command_bytes(
        "git",
        &[
            "-C",
            repo_root,
            "ls-files",
            "--others",
            "--exclude-standard",
            "-z",
            "--",
            "crates",
            "vendor",
        ],
    )?;
    if tracked_diff.is_empty() && untracked.is_empty() {
        return Some(head);
    }

    let mut hasher = Sha256::new();
    hasher.update(head.as_bytes());
    hasher.update([0]);
    hasher.update(tracked_diff);
    for path in untracked
        .split(|byte| *byte == 0)
        .filter(|path| !path.is_empty())
    {
        hasher.update(path);
        hasher.update([0]);
        let path = std::str::from_utf8(path).ok()?;
        hasher.update(std::fs::read(PathBuf::from(repo_root).join(path)).ok()?);
        hasher.update([0]);
    }
    Some(format!("{head}-dirty.{:x}", hasher.finalize()))
}

fn resolved_source_revision(repo_root: &std::path::Path, requested: Option<String>) -> String {
    let actual =
        git_revision(repo_root).expect("cannot derive the exact runtime source identity from Git");
    if let Some(requested) = requested {
        assert_eq!(
            requested, actual,
            "NUX_RUNTIME_SOURCE_REVISION must match the exact clean or content-bound dirty Git identity"
        );
    }
    actual
}

fn command_output(command: String, arguments: &[&str]) -> Option<String> {
    let output = Command::new(command).args(arguments).output().ok()?;
    if !output.status.success() {
        return None;
    }
    String::from_utf8(output.stdout)
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

fn command_bytes(command: &str, arguments: &[&str]) -> Option<Vec<u8>> {
    let output = Command::new(command).args(arguments).output().ok()?;
    output.status.success().then_some(output.stdout)
}

fn json_escape(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
}

fn verify_generated_header() -> String {
    let crate_dir = PathBuf::from(std::env::var_os("CARGO_MANIFEST_DIR").expect("manifest dir"));
    let config = cbindgen::Config::from_file(crate_dir.join("cbindgen.toml"))
        .expect("read nux-apple-runtime cbindgen config");
    let bindings = cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .expect("generate Nuxie runtime C header");
    let generated_path = PathBuf::from(std::env::var_os("OUT_DIR").expect("OUT_DIR"))
        .join("nux_runtime.generated.h");
    bindings.write_to_file(&generated_path);
    let generated = std::fs::read(&generated_path).expect("read generated runtime header");

    let committed_path = crate_dir.join("include/nux_runtime.generated.h");
    if std::env::var_os("NUX_RUNTIME_UPDATE_HEADER").is_some() {
        std::fs::copy(&generated_path, &committed_path).expect("update generated runtime header");
    } else {
        assert_eq!(
            std::fs::read(&committed_path).unwrap_or_default(),
            generated,
            "generated runtime header is stale; run NUX_RUNTIME_UPDATE_HEADER=1 cargo build -p nux-apple-runtime --features apple-product"
        );
    }
    format!("{:x}", Sha256::digest(&generated))
}
