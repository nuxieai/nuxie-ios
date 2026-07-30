#[path = "../src/experience_package.rs"]
mod experience_package;

use experience_package::{
    CandidateExperienceSigningKey, ExperiencePackageImportInput, ExternalAssetInput,
    ExternalAssetKind, validate_experience_package_import,
};
use nux_container::test_support::{TEST_ONLY_DEV_KEY_ID, TEST_ONLY_DEV_KEYPAIR};
use nux_container::{
    AssetLocation, Assets, Entry, Identity, ImageAsset, ImageContentType, JourneyMember,
    LuauProducer, NuxPackageManifestV1, NuxPackageModel, Producer, SceneFormat, SceneMember,
    Screen, SignatureEnvelopeV1, SignatureSource, write_package,
};
use sha2::{Digest as _, Sha256};

fn fixture_bytes() -> Vec<u8> {
    let fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("fixtures/minimal/two_artboards.riv");
    std::fs::read(fixture).expect("fixture must be readable")
}

fn manifest() -> NuxPackageManifestV1 {
    NuxPackageManifestV1 {
        version: 1,
        identity: Identity {
            experience_id: "test-experience".to_owned(),
            build_id: "test-build".to_owned(),
            app_id: "test-app".to_owned(),
            environment: "test".to_owned(),
        },
        producer: Producer {
            compiler_commit: "test".to_owned(),
            compiler_version: "test".to_owned(),
            runtime_revision: "test".to_owned(),
            luau: LuauProducer {
                revision: "test".to_owned(),
                bytecode_versions: vec![3],
            },
            min_runtime: "0.2.0".to_owned(),
        },
        scene_format: SceneFormat { major: 7, minor: 0 },
        required_capabilities: Vec::new(),
        scene: SceneMember {
            member: "scene".to_owned(),
            sha256: "0".repeat(64),
            size_bytes: 0,
        },
        journey: JourneyMember {
            member: "journey".to_owned(),
            sha256: "0".repeat(64),
            size_bytes: 0,
            schema_version: 1,
        },
        entry: Entry {
            screen_id: "screen".to_owned(),
        },
        screens: vec![Screen {
            screen_id: "screen".to_owned(),
            artboard_id: "artboard".to_owned(),
            artboard_name: "Artboard".to_owned(),
            width: 390.0,
            height: 844.0,
        }],
        text_inputs: Vec::new(),
        assets: Assets::default(),
        members: Vec::new(),
    }
}

fn signed_package(scene: &[u8], manifest: NuxPackageManifestV1) -> Vec<u8> {
    write_package(&NuxPackageModel {
        manifest,
        scene,
        journey: br#"{"schemaVersion":1}"#,
        embedded_assets: Vec::new(),
        signature: SignatureSource::Signer(&*TEST_ONLY_DEV_KEYPAIR),
    })
    .expect("test package must encode")
}

fn package_with_envelope(
    scene: &[u8],
    manifest: NuxPackageManifestV1,
    envelope: &SignatureEnvelopeV1,
) -> Vec<u8> {
    write_package(&NuxPackageModel {
        manifest,
        scene,
        journey: br#"{"schemaVersion":1}"#,
        embedded_assets: Vec::new(),
        signature: SignatureSource::Precomputed(envelope),
    })
    .expect("test package must encode")
}

fn input(package_bytes: Vec<u8>) -> ExperiencePackageImportInput {
    ExperiencePackageImportInput {
        expected_experience_id: "test-experience".to_owned(),
        expected_build_id: "test-build".to_owned(),
        package_bytes,
        candidate_keys: vec![CandidateExperienceSigningKey {
            key_id: TEST_ONLY_DEV_KEY_ID.to_owned(),
            public_key: TEST_ONLY_DEV_KEYPAIR.public_key(),
        }],
        external_assets: Vec::new(),
    }
}

fn error_code(input: ExperiencePackageImportInput) -> &'static str {
    match validate_experience_package_import(input) {
        Ok(_) => panic!("package import must fail"),
        Err(error) => error.code,
    }
}

#[test]
fn signed_package_imports_the_scene_with_scripts_authorized() {
    let package = signed_package(&fixture_bytes(), manifest());
    let validated =
        validate_experience_package_import(input(package)).expect("signed package must import");

    assert_eq!(validated.authenticated_key_id, TEST_ONLY_DEV_KEY_ID);
    assert!(validated.diagnostics.is_empty());
    assert!(validated.external_assets.is_empty());
    assert_eq!(validated.file.artboard_count(), 2);
}

#[test]
fn unsigned_package_is_refused() {
    let mut package = signed_package(&fixture_bytes(), manifest());
    let name = package
        .windows(b"signature".len())
        .position(|window| window == b"signature")
        .expect("signature ToC name must exist");
    package[name] = b'x';

    assert_eq!(error_code(input(package)), "package.signature.missing");
}

#[test]
fn malformed_signature_envelope_is_refused() {
    let envelope = SignatureEnvelopeV1 {
        version: 2,
        signs: "manifest".to_owned(),
        algorithm: "ed25519".to_owned(),
        key_id: TEST_ONLY_DEV_KEY_ID.to_owned(),
        signature_base64: "not-base64".to_owned(),
    };
    let package = package_with_envelope(&fixture_bytes(), manifest(), &envelope);

    assert_eq!(error_code(input(package)), "package.signature.malformed");
}

#[test]
fn unknown_key_is_refused() {
    let package = signed_package(&fixture_bytes(), manifest());
    let mut request = input(package);
    request.candidate_keys.clear();

    assert_eq!(error_code(request), "package.signature.unknown_key");
}

#[test]
fn bad_signature_is_refused() {
    let package = signed_package(&fixture_bytes(), manifest());
    let mut request = input(package);
    request.candidate_keys[0].public_key = [0x24; 32];

    assert_eq!(error_code(request), "package.signature.bad_signature");
}

#[test]
fn tampered_manifest_is_refused() {
    let mut package = signed_package(&fixture_bytes(), manifest());
    let identity = b"test-experience";
    let offset = package
        .windows(identity.len())
        .position(|window| window == identity)
        .expect("manifest identity must exist");
    package[offset] = b'f';

    assert_eq!(
        error_code(input(package)),
        "package.signature.bad_signature"
    );
}

#[test]
fn identity_mismatch_is_refused() {
    let package = signed_package(&fixture_bytes(), manifest());
    let mut request = input(package);
    request.expected_experience_id = "another-experience".to_owned();

    assert_eq!(error_code(request), "package.identity.mismatch");
}

#[test]
fn unknown_required_capability_is_refused() {
    let mut package_manifest = manifest();
    package_manifest
        .required_capabilities
        .push("future.capability".to_owned());
    let package = signed_package(&fixture_bytes(), package_manifest);

    assert_eq!(error_code(input(package)), "package.capability.unknown");
}

#[test]
fn required_external_asset_missing_is_refused() {
    let scene = external_asset_riv();
    let bytes = b"encoded image bytes";
    let package_manifest = manifest_with_external_image(bytes, true);
    let package = signed_package(&scene, package_manifest);

    assert_eq!(error_code(input(package)), "package.asset_table.mismatch");
}

#[test]
fn required_external_asset_with_matching_host_evidence_is_accepted() {
    let scene = external_asset_riv();
    let bytes = b"encoded image bytes";
    let digest = sha256_hex(bytes);
    let source_key = format!("assets/sha256/{digest}.png");
    let package = signed_package(&scene, manifest_with_external_image(bytes, true));
    let mut request = input(package);
    request.external_assets.push(ExternalAssetInput::Supplied {
        kind: ExternalAssetKind::Image,
        asset_id: 1,
        unique_name: "image-1".to_owned(),
        source_key,
        expected_sha256: digest,
        required: true,
        bytes: bytes.to_vec(),
    });

    let validated =
        validate_experience_package_import(request).expect("matching host evidence must import");

    assert_eq!(validated.external_assets.len(), 1);
    let asset = validated
        .external_assets
        .first()
        .expect("one validated asset");
    assert_eq!(asset.bytes.as_deref(), Some(bytes.as_slice()));
    assert!(validated.diagnostics.is_empty());
}

#[test]
fn optional_external_asset_may_be_explicitly_omitted() {
    let scene = external_asset_riv();
    let bytes = b"encoded image bytes";
    let digest = sha256_hex(bytes);
    let source_key = format!("assets/sha256/{digest}.png");
    let package = signed_package(&scene, manifest_with_external_image(bytes, false));
    let mut request = input(package);
    request.external_assets.push(ExternalAssetInput::Omitted {
        kind: ExternalAssetKind::Image,
        asset_id: 1,
        unique_name: "image-1".to_owned(),
        source_key,
        expected_sha256: digest,
        required: false,
    });

    let validated =
        validate_experience_package_import(request).expect("optional asset omission must import");

    assert_eq!(validated.external_assets.len(), 1);
    assert!(
        validated
            .external_assets
            .first()
            .expect("one validated asset")
            .bytes
            .is_none()
    );
    assert_eq!(validated.diagnostics.len(), 1);
    let diagnostic = validated.diagnostics.first().expect("one diagnostic");
    assert_eq!(diagnostic.code, "package.asset.optional_missing");
}

fn manifest_with_external_image(bytes: &[u8], required: bool) -> NuxPackageManifestV1 {
    let digest = sha256_hex(bytes);
    let mut package_manifest = manifest();
    package_manifest.assets.images.push(ImageAsset {
        location: AssetLocation::External {
            key: format!("assets/sha256/{digest}.png"),
        },
        rive_asset_id: 1,
        rive_unique_name: "image-1".to_owned(),
        sha256: digest,
        size_bytes: bytes.len() as u64,
        content_type: ImageContentType::Png,
        required,
    });
    package_manifest
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn push_var_uint(bytes: &mut Vec<u8>, mut value: u64) {
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        bytes.push(byte);
        if value == 0 {
            break;
        }
    }
}

fn property_key(type_name: &str, property_name: &str) -> u16 {
    let definition = nuxie_schema::definition_by_name(type_name).expect("fixture type exists");
    definition
        .properties
        .iter()
        .chain(definition.ancestors.iter().flat_map(|ancestor| {
            nuxie_schema::definition_by_name(ancestor)
                .expect("fixture ancestor exists")
                .properties
                .iter()
        }))
        .find(|property| property.name == property_name)
        .expect("fixture property exists")
        .key
        .int
}

fn push_object(bytes: &mut Vec<u8>, type_name: &str, properties: impl FnOnce(&mut Vec<u8>)) {
    push_var_uint(
        bytes,
        u64::from(
            nuxie_schema::definition_by_name(type_name)
                .expect("fixture type exists")
                .type_key
                .int,
        ),
    );
    properties(bytes);
    push_var_uint(bytes, 0);
}

fn push_uint(bytes: &mut Vec<u8>, type_name: &str, name: &str, value: u64) {
    push_var_uint(bytes, u64::from(property_key(type_name, name)));
    push_var_uint(bytes, value);
}

fn push_blob(bytes: &mut Vec<u8>, type_name: &str, name: &str, value: &[u8]) {
    push_var_uint(bytes, u64::from(property_key(type_name, name)));
    push_var_uint(bytes, value.len() as u64);
    bytes.extend_from_slice(value);
}

fn push_string(bytes: &mut Vec<u8>, type_name: &str, name: &str, value: &str) {
    push_blob(bytes, type_name, name, value.as_bytes());
}

fn external_asset_riv() -> Vec<u8> {
    let mut bytes = b"RIVE".to_vec();
    push_var_uint(&mut bytes, 7);
    push_var_uint(&mut bytes, 0);
    push_var_uint(&mut bytes, 992);
    push_var_uint(&mut bytes, 0);
    push_object(&mut bytes, "Backboard", |_| {});
    push_object(&mut bytes, "ImageAsset", |bytes| {
        push_uint(bytes, "ImageAsset", "assetId", 1);
        push_string(bytes, "ImageAsset", "name", "image.png");
    });
    push_object(&mut bytes, "Artboard", |_| {});
    bytes
}
