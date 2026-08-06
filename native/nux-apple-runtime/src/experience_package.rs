//! Verification and import of signed Nuxie experience packages.

use std::collections::{BTreeMap, BTreeSet};

use nux_container::{
    AssetLocation, NUX_MAX_EXTERNAL_ASSET_BYTES, NuxContainerError, SignatureVerification,
    read_package, verify_signature,
};
use nuxie::{File, ScriptExecutionLimits};
use nuxie_product::scripting::ScriptImportCapability;
use sha2::{Digest as _, Sha256};

pub(crate) const MAX_EXTERNAL_ASSET_COUNT: usize = 1_024;
const MAX_ASSET_UNIQUE_NAME_BYTE_LENGTH: usize = 4_096;
const MAX_ASSET_SOURCE_KEY_BYTE_LENGTH: usize = 4_194_304;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CandidateExperienceSigningKey {
    pub(crate) key_id: String,
    pub(crate) public_key: [u8; 32],
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ExternalAssetKind {
    Image,
    Font,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ExternalAssetInput {
    Supplied {
        kind: ExternalAssetKind,
        asset_id: u32,
        unique_name: String,
        source_key: String,
        expected_sha256: String,
        required: bool,
        bytes: Vec<u8>,
    },
    Omitted {
        kind: ExternalAssetKind,
        asset_id: u32,
        unique_name: String,
        source_key: String,
        expected_sha256: String,
        required: bool,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum PackageDiagnosticSeverity {
    Warning,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PackageDiagnostic {
    pub(crate) severity: PackageDiagnosticSeverity,
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ValidatedExternalAsset {
    pub(crate) kind: ExternalAssetKind,
    pub(crate) asset_id: u32,
    pub(crate) unique_name: String,
    pub(crate) required: bool,
    pub(crate) bytes: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ExperiencePackageImportInput {
    pub(crate) expected_experience_id: String,
    pub(crate) expected_build_id: String,
    pub(crate) package_bytes: Vec<u8>,
    pub(crate) candidate_keys: Vec<CandidateExperienceSigningKey>,
    pub(crate) external_assets: Vec<ExternalAssetInput>,
}

pub(crate) struct ValidatedExperiencePackageImport {
    pub(crate) file: File,
    pub(crate) authenticated_key_id: String,
    pub(crate) external_assets: Vec<ValidatedExternalAsset>,
    pub(crate) diagnostics: Vec<PackageDiagnostic>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PackageImportError {
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

impl std::fmt::Display for PackageImportError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for PackageImportError {}

struct ExternalAssetDeclaration {
    kind: ExternalAssetKind,
    asset_id: u32,
    unique_name: String,
    source_key: Option<String>,
    sha256: String,
    size_bytes: u64,
    required: bool,
    embedded_bytes: Option<Vec<u8>>,
}

pub(crate) fn validate_experience_package_import(
    input: ExperiencePackageImportInput,
) -> Result<ValidatedExperiencePackageImport, PackageImportError> {
    let package = read_package(&input.package_bytes).map_err(container_error)?;
    let (authenticated_key_id, verified_scene) = match verify_signature(
        &package,
        input
            .candidate_keys
            .iter()
            .map(|key| (key.key_id.as_str(), key.public_key)),
    ) {
        SignatureVerification::Verified { key_id, scene } => (key_id, scene),
        SignatureVerification::UnknownKey => {
            return Err(import_error(
                "package.signature.unknown_key",
                "package signature names no candidate public key",
            ));
        }
        SignatureVerification::BadSignature => {
            return Err(import_error(
                "package.signature.bad_signature",
                "package signature does not authenticate the exact manifest bytes",
            ));
        }
        SignatureVerification::MalformedEnvelope => {
            return Err(import_error(
                "package.signature.malformed",
                "package signature envelope is malformed or unsupported",
            ));
        }
    };

    let manifest = package.manifest();
    if manifest.identity.experience_id != input.expected_experience_id
        || manifest.identity.build_id != input.expected_build_id
    {
        return Err(import_error(
            "package.identity.mismatch",
            format!(
                "package identity '{}@{}' does not match requested identity '{}@{}'",
                manifest.identity.experience_id,
                manifest.identity.build_id,
                input.expected_experience_id,
                input.expected_build_id
            ),
        ));
    }

    let declarations = asset_declarations(&package)?;
    let mut diagnostics = Vec::new();
    let external_assets =
        validate_external_assets(&declarations, input.external_assets, &mut diagnostics)?;

    let scene_bytes = verified_scene.bytes();
    let script_capability =
        ScriptImportCapability::authenticated_for_verified_scene(verified_scene)
            .map_err(|error| import_error("package.scene.import_failed", error.to_string()))?;
    let file = nuxie_product::scripting::import_authenticated_file(
        scene_bytes,
        script_capability,
        ScriptExecutionLimits::new(),
    )
    .map_err(|error| import_error("package.scene.import_failed", error.to_string()))?;
    validate_riv_asset_catalog(&file, &declarations)?;

    Ok(ValidatedExperiencePackageImport {
        file,
        authenticated_key_id,
        external_assets,
        diagnostics,
    })
}

fn container_error(error: NuxContainerError) -> PackageImportError {
    let code = match error {
        NuxContainerError::MissingMember("signature") => "package.signature.missing",
        NuxContainerError::ZeroLengthMember(ref member) if member == "signature" => {
            "package.signature.malformed"
        }
        NuxContainerError::PackageTooLarge { .. }
        | NuxContainerError::MemberTooLarge { .. }
        | NuxContainerError::TooManyMembers { .. } => "package.oversize",
        NuxContainerError::UnknownCapability(_) => "package.capability.unknown",
        _ => "package.container.parse_failure",
    };
    import_error(code, error.to_string())
}

fn asset_declarations(
    package: &nux_container::NuxPackage<'_>,
) -> Result<Vec<ExternalAssetDeclaration>, PackageImportError> {
    let manifest = package.manifest();
    let declaration_count = manifest
        .assets
        .images
        .len()
        .checked_add(manifest.assets.fonts.len())
        .ok_or_else(|| asset_mismatch("asset declaration count overflowed"))?;
    if declaration_count > MAX_EXTERNAL_ASSET_COUNT {
        return Err(asset_mismatch(format!(
            "package declares {declaration_count} assets; the limit is {MAX_EXTERNAL_ASSET_COUNT}"
        )));
    }

    let mut declarations = Vec::with_capacity(declaration_count);
    for image in &manifest.assets.images {
        declarations.push(declaration(
            package,
            ExternalAssetKind::Image,
            image.rive_asset_id,
            &image.rive_unique_name,
            &image.location,
            &image.sha256,
            image.size_bytes,
            image.required,
        )?);
    }
    for font in &manifest.assets.fonts {
        declarations.push(declaration(
            package,
            ExternalAssetKind::Font,
            font.rive_asset_id,
            &font.rive_unique_name,
            &font.location,
            &font.sha256,
            font.size_bytes,
            font.required,
        )?);
    }

    let mut ids = BTreeSet::new();
    let mut unique_names = BTreeSet::new();
    for declaration in &declarations {
        if !ids.insert(declaration.asset_id) {
            return Err(asset_mismatch(format!(
                "package declares asset id {} more than once",
                declaration.asset_id
            )));
        }
        if !unique_names.insert(declaration.unique_name.as_str()) {
            return Err(asset_mismatch(format!(
                "package declares asset unique name '{}' more than once",
                declaration.unique_name
            )));
        }
    }
    Ok(declarations)
}

#[allow(clippy::too_many_arguments)]
fn declaration(
    package: &nux_container::NuxPackage<'_>,
    kind: ExternalAssetKind,
    asset_id: u64,
    unique_name: &str,
    location: &AssetLocation,
    sha256: &str,
    size_bytes: u64,
    required: bool,
) -> Result<ExternalAssetDeclaration, PackageImportError> {
    let asset_id = u32::try_from(asset_id)
        .map_err(|_| asset_mismatch(format!("asset '{unique_name}' id does not fit in UInt32")))?;
    if unique_name.is_empty() || unique_name.len() > MAX_ASSET_UNIQUE_NAME_BYTE_LENGTH {
        return Err(asset_mismatch(format!(
            "asset {asset_id} has an invalid unique name"
        )));
    }
    let (source_key, embedded_bytes) = match location {
        AssetLocation::External { key } => {
            if size_bytes > NUX_MAX_EXTERNAL_ASSET_BYTES {
                return Err(import_error(
                    "package.oversize",
                    format!(
                        "external asset {asset_id} '{unique_name}' declares {size_bytes} bytes; the limit is {NUX_MAX_EXTERNAL_ASSET_BYTES}"
                    ),
                ));
            }
            if key.is_empty() || key.len() > MAX_ASSET_SOURCE_KEY_BYTE_LENGTH {
                return Err(asset_mismatch(format!(
                    "asset {asset_id} '{unique_name}' has an invalid external key"
                )));
            }
            (Some(key.clone()), None)
        }
        AssetLocation::Embedded { member } => {
            let bytes = package.member(member).ok_or_else(|| {
                asset_mismatch(format!(
                    "embedded asset {asset_id} '{unique_name}' is missing member '{member}'"
                ))
            })?;
            (None, Some(bytes.to_vec()))
        }
    };
    Ok(ExternalAssetDeclaration {
        kind,
        asset_id,
        unique_name: unique_name.to_owned(),
        source_key,
        sha256: sha256.to_owned(),
        size_bytes,
        required,
        embedded_bytes,
    })
}

fn validate_external_assets(
    declarations: &[ExternalAssetDeclaration],
    inputs: Vec<ExternalAssetInput>,
    diagnostics: &mut Vec<PackageDiagnostic>,
) -> Result<Vec<ValidatedExternalAsset>, PackageImportError> {
    let mut inputs_by_id = BTreeMap::new();
    let mut input_unique_names = BTreeSet::new();
    for input in inputs {
        let (asset_id, unique_name) = input_identity(&input);
        let unique_name = unique_name.to_owned();
        if inputs_by_id.insert(asset_id, input).is_some()
            || !input_unique_names.insert(unique_name.clone())
        {
            return Err(asset_mismatch(format!(
                "host asset {asset_id} '{unique_name}' appears more than once"
            )));
        }
    }

    let mut validated = Vec::with_capacity(declarations.len());
    for declaration in declarations {
        if let Some(bytes) = declaration.embedded_bytes.as_ref() {
            if inputs_by_id.contains_key(&declaration.asset_id) {
                return Err(asset_mismatch(format!(
                    "embedded asset {} '{}' must not appear in the host asset table",
                    declaration.asset_id, declaration.unique_name
                )));
            }
            validated.push(ValidatedExternalAsset {
                kind: declaration.kind,
                asset_id: declaration.asset_id,
                unique_name: declaration.unique_name.clone(),
                required: declaration.required,
                bytes: Some(bytes.clone()),
            });
            continue;
        }

        let Some(input) = inputs_by_id.remove(&declaration.asset_id) else {
            if declaration.required {
                return Err(asset_mismatch(format!(
                    "required external asset {} '{}' is missing",
                    declaration.asset_id, declaration.unique_name
                )));
            }
            diagnostics.push(optional_missing_diagnostic(declaration));
            validated.push(ValidatedExternalAsset {
                kind: declaration.kind,
                asset_id: declaration.asset_id,
                unique_name: declaration.unique_name.clone(),
                required: false,
                bytes: None,
            });
            continue;
        };
        let (kind, asset_id, unique_name, source_key, expected_sha256, required, bytes) =
            input_parts(input);
        let declared_source_key = declaration
            .source_key
            .as_deref()
            .ok_or_else(|| asset_mismatch("external asset declaration has no source key"))?;
        if kind != declaration.kind
            || unique_name != declaration.unique_name
            || source_key != declared_source_key
            || expected_sha256 != declaration.sha256
            || required != declaration.required
        {
            return Err(asset_mismatch(format!(
                "host evidence for asset {asset_id} '{unique_name}' does not match the signed manifest"
            )));
        }
        if let Some(bytes) = bytes.as_ref() {
            let actual_size = u64::try_from(bytes.len())
                .map_err(|_| asset_mismatch("asset byte length does not fit in UInt64"))?;
            if actual_size != declaration.size_bytes || sha256_hex(bytes) != declaration.sha256 {
                return Err(asset_mismatch(format!(
                    "host bytes for asset {asset_id} '{unique_name}' do not match the signed size and digest"
                )));
            }
        } else if declaration.required {
            return Err(asset_mismatch(format!(
                "required external asset {asset_id} '{unique_name}' was omitted"
            )));
        } else {
            diagnostics.push(optional_missing_diagnostic(declaration));
        }
        validated.push(ValidatedExternalAsset {
            kind,
            asset_id,
            unique_name,
            required,
            bytes,
        });
    }

    if let Some((asset_id, input)) = inputs_by_id.into_iter().next() {
        let (_, unique_name) = input_identity(&input);
        return Err(asset_mismatch(format!(
            "host asset {asset_id} '{unique_name}' is not an external asset declared by the package"
        )));
    }
    Ok(validated)
}

#[allow(clippy::type_complexity)]
fn input_parts(
    input: ExternalAssetInput,
) -> (
    ExternalAssetKind,
    u32,
    String,
    String,
    String,
    bool,
    Option<Vec<u8>>,
) {
    match input {
        ExternalAssetInput::Supplied {
            kind,
            asset_id,
            unique_name,
            source_key,
            expected_sha256,
            required,
            bytes,
        } => (
            kind,
            asset_id,
            unique_name,
            source_key,
            expected_sha256,
            required,
            Some(bytes),
        ),
        ExternalAssetInput::Omitted {
            kind,
            asset_id,
            unique_name,
            source_key,
            expected_sha256,
            required,
        } => (
            kind,
            asset_id,
            unique_name,
            source_key,
            expected_sha256,
            required,
            None,
        ),
    }
}

fn input_identity(input: &ExternalAssetInput) -> (u32, &str) {
    match input {
        ExternalAssetInput::Supplied {
            asset_id,
            unique_name,
            ..
        }
        | ExternalAssetInput::Omitted {
            asset_id,
            unique_name,
            ..
        } => (*asset_id, unique_name),
    }
}

fn optional_missing_diagnostic(declaration: &ExternalAssetDeclaration) -> PackageDiagnostic {
    PackageDiagnostic {
        severity: PackageDiagnosticSeverity::Warning,
        code: "package.asset.optional_missing",
        message: format!(
            "optional external asset {} '{}' was omitted",
            declaration.asset_id, declaration.unique_name
        ),
    }
}

fn validate_riv_asset_catalog(
    file: &File,
    declarations: &[ExternalAssetDeclaration],
) -> Result<(), PackageImportError> {
    let mut assets_by_id = BTreeMap::new();
    for asset in file.runtime().file_assets() {
        let Some(raw_asset_id) = asset.uint_property("assetId") else {
            continue;
        };
        let Ok(asset_id) = u32::try_from(raw_asset_id) else {
            continue;
        };
        if assets_by_id.insert(asset_id, asset).is_some() {
            return Err(asset_mismatch(format!(
                "scene catalog contains asset id {asset_id} more than once"
            )));
        }
    }

    for declaration in declarations {
        let Some(asset) = assets_by_id.get(&declaration.asset_id) else {
            return Err(asset_mismatch(format!(
                "asset {} '{}' is absent from the scene catalog",
                declaration.asset_id, declaration.unique_name
            )));
        };
        let expected_type = match declaration.kind {
            ExternalAssetKind::Image => "ImageAsset",
            ExternalAssetKind::Font => "FontAsset",
        };
        if asset.type_name != expected_type
            || asset.file_asset_unique_name().as_deref() != Some(&declaration.unique_name)
        {
            return Err(asset_mismatch(format!(
                "asset {} '{}' does not match the scene catalog",
                declaration.asset_id, declaration.unique_name
            )));
        }
    }
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn asset_mismatch(message: impl Into<String>) -> PackageImportError {
    import_error("package.asset_table.mismatch", message)
}

fn import_error(code: &'static str, message: impl Into<String>) -> PackageImportError {
    PackageImportError {
        code,
        message: message.into(),
    }
}
