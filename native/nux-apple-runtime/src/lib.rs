//! Product C ABI for the Nuxie Apple experience runtime.

#[cfg(feature = "apple-product")]
mod experience_package;
mod session;

pub use session::*;

#[cfg(all(feature = "apple-product", panic = "abort"))]
compile_error!(
    "nux-apple-runtime's apple-product feature requires panic=unwind; use the release-apple profile"
);

#[cfg(feature = "apple-product")]
use std::ffi::CStr;
use std::ffi::{c_char, c_void};
use std::panic::{self, AssertUnwindSafe};
use std::ptr;
use std::slice;

#[cfg(feature = "apple-product")]
use experience_package::{
    CandidateExperienceSigningKey, ExperiencePackageImportInput, ExternalAssetInput,
    ExternalAssetKind, MAX_EXTERNAL_ASSET_COUNT, PackageDiagnosticSeverity,
    validate_experience_package_import,
};
#[cfg(feature = "apple-product")]
use nuxie::{
    ApplePresentationCompletion, AppleSurface, File, Mat2D, RenderMode, Renderer,
    SurfaceDisposition, WgpuFactory,
    flow_session::{FlowPlayerSelector, FlowSession, FlowSessionConfig, FlowSessionErrorKind},
};
#[cfg(feature = "apple-product")]
use std::{
    collections::HashMap,
    sync::{
        Arc, Mutex,
        mpsc::{self, Receiver, Sender},
    },
    thread::{self, JoinHandle, ThreadId},
};

const MAX_AUTHORIZATION_KEY_ID_BYTE_LENGTH: usize = 256;
#[cfg(feature = "apple-product")]
const MAX_CANDIDATE_KEY_COUNT: usize = 256;
const ED25519_PUBLIC_KEY_BYTE_LENGTH: usize = 32;
const MAX_EXTERNAL_ASSET_TOTAL_BYTE_LENGTH: usize = 134_217_728;
const MAX_SELECTOR_BYTE_LENGTH: usize = 4_096;
const MAX_ASSET_SOURCE_KEY_BYTE_LENGTH: usize = 4_194_304;
const PANIC_DIAGNOSTIC: &str = "runtime panicked; the affected screen session is terminated";
const RESULT_LIMIT_DIAGNOSTIC_CODE: &[u8] = b"nux_runtime.result_limit_exceeded";
const SCRIPT_RESOURCE_DIAGNOSTIC_CODE: &[u8] = b"nux_runtime.script_resource_exceeded";
const RUNTIME_VERSION: &str = env!("CARGO_PKG_VERSION");
const SOURCE_REVISION: &str = env!("NUX_RUNTIME_SOURCE_REVISION");
const BUILD_PROVENANCE: &str = env!("NUX_RUNTIME_BUILD_PROVENANCE");
const MAX_RUNTIME_IDENTITY_PART_BYTE_LENGTH: usize = 4_096;

static RUNTIME_BINDING_TOKEN: u8 = 0;

fn ffi_guard<R>(fallback: R, body: impl FnOnce() -> R) -> R {
    match panic::catch_unwind(AssertUnwindSafe(body)) {
        Ok(value) => value,
        Err(_) => fallback,
    }
}

fn ffi_guard_with_result(
    out_result: *mut *mut NuxOperationResult,
    on_panic: impl FnOnce(),
    body: impl FnOnce() -> NuxStatus,
) -> NuxStatus {
    match panic::catch_unwind(AssertUnwindSafe(body)) {
        Ok(status) => status,
        Err(_) => {
            let _ = panic::catch_unwind(AssertUnwindSafe(on_panic));
            replace_result(
                out_result,
                NuxOperationResult::failure(NuxStatus::RuntimeError, PANIC_DIAGNOSTIC),
            );
            NuxStatus::RuntimeError
        }
    }
}

/// Stable-width C status code. Named constants are exported separately so
/// Swift imports one unambiguous `UInt32`-backed type instead of a C enum tag
/// that competes with its typedef.
pub type NuxStatus = u32;

pub const NUX_STATUS_OK: NuxStatus = 0 as NuxStatus;
pub const NUX_STATUS_NULL_ARGUMENT: NuxStatus = 1 as NuxStatus;
pub const NUX_STATUS_IMPORT_ERROR: NuxStatus = 2 as NuxStatus;
pub const NUX_STATUS_NOT_FOUND: NuxStatus = 3 as NuxStatus;
pub const NUX_STATUS_RUNTIME_ERROR: NuxStatus = 4 as NuxStatus;
pub const NUX_STATUS_INVALID_ARGUMENT: NuxStatus = 5 as NuxStatus;
pub const NUX_STATUS_RUNTIME_IDENTITY_MISMATCH: NuxStatus = 6 as NuxStatus;
pub const NUX_STATUS_SURFACE_ERROR: NuxStatus = 7 as NuxStatus;

/// Stable-width structured diagnostic severity.
pub type NuxDiagnosticSeverity = u32;

pub const NUX_DIAGNOSTIC_SEVERITY_DEBUG: NuxDiagnosticSeverity = 0;
pub const NUX_DIAGNOSTIC_SEVERITY_WARNING: NuxDiagnosticSeverity = 1;
pub const NUX_DIAGNOSTIC_SEVERITY_FATAL: NuxDiagnosticSeverity = 2;

/// Stable-width external experience asset kind.
pub type NuxExperienceExternalAssetKind = u32;

pub const NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_IMAGE: NuxExperienceExternalAssetKind = 1;
pub const NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_FONT: NuxExperienceExternalAssetKind = 2;

/// Stable-width C presentation outcome.
pub type NuxSurfaceDisposition = u32;

pub const NUX_SURFACE_DISPOSITION_NONE: NuxSurfaceDisposition = 0 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_PRESENTED: NuxSurfaceDisposition = 1 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE: NuxSurfaceDisposition =
    2 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT: NuxSurfaceDisposition =
    3 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_SKIPPED_OCCLUDED: NuxSurfaceDisposition =
    4 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_RECONFIGURED: NuxSurfaceDisposition = 5 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_RECREATED: NuxSurfaceDisposition = 6 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_DEVICE_LOST: NuxSurfaceDisposition = 7 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_OUT_OF_MEMORY: NuxSurfaceDisposition = 8 as NuxSurfaceDisposition;
pub const NUX_SURFACE_DISPOSITION_FATAL: NuxSurfaceDisposition = 9 as NuxSurfaceDisposition;

// Keep the internal implementation readable while the public C surface uses
// fixed-width aliases and exported constants.
#[allow(dead_code, non_upper_case_globals)]
trait NuxStatusConstants {
    const Ok: NuxStatus = NUX_STATUS_OK;
    const NullArgument: NuxStatus = NUX_STATUS_NULL_ARGUMENT;
    const ImportError: NuxStatus = NUX_STATUS_IMPORT_ERROR;
    const NotFound: NuxStatus = NUX_STATUS_NOT_FOUND;
    const RuntimeError: NuxStatus = NUX_STATUS_RUNTIME_ERROR;
    const InvalidArgument: NuxStatus = NUX_STATUS_INVALID_ARGUMENT;
    const RuntimeIdentityMismatch: NuxStatus = NUX_STATUS_RUNTIME_IDENTITY_MISMATCH;
    const SurfaceError: NuxStatus = NUX_STATUS_SURFACE_ERROR;
}

impl NuxStatusConstants for u32 {}

#[allow(dead_code, non_upper_case_globals)]
trait NuxSurfaceDispositionConstants {
    const None: NuxSurfaceDisposition = NUX_SURFACE_DISPOSITION_NONE;
    const Presented: NuxSurfaceDisposition = NUX_SURFACE_DISPOSITION_PRESENTED;
    const SkippedTimeout: NuxSurfaceDisposition = NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT;
    const Recreated: NuxSurfaceDisposition = NUX_SURFACE_DISPOSITION_RECREATED;
    const Fatal: NuxSurfaceDisposition = NUX_SURFACE_DISPOSITION_FATAL;
}

impl NuxSurfaceDispositionConstants for u32 {}

#[cfg(feature = "apple-product")]
fn surface_disposition(value: SurfaceDisposition) -> NuxSurfaceDisposition {
    match value {
        SurfaceDisposition::None => NUX_SURFACE_DISPOSITION_NONE,
        SurfaceDisposition::Presented => NUX_SURFACE_DISPOSITION_PRESENTED,
        SurfaceDisposition::SkippedZeroSize => NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE,
        SurfaceDisposition::SkippedTimeout => NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT,
        SurfaceDisposition::SkippedOccluded => NUX_SURFACE_DISPOSITION_SKIPPED_OCCLUDED,
        SurfaceDisposition::Reconfigured => NUX_SURFACE_DISPOSITION_RECONFIGURED,
        SurfaceDisposition::Recreated => NUX_SURFACE_DISPOSITION_RECREATED,
        SurfaceDisposition::DeviceLost => NUX_SURFACE_DISPOSITION_DEVICE_LOST,
        SurfaceDisposition::OutOfMemory => NUX_SURFACE_DISPOSITION_OUT_OF_MEMORY,
        SurfaceDisposition::Fatal => NUX_SURFACE_DISPOSITION_FATAL,
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxByteView {
    pub data: *const u8,
    pub len: u64,
}

impl Default for NuxByteView {
    fn default() -> Self {
        Self {
            data: ptr::null(),
            len: 0,
        }
    }
}

impl NuxByteView {
    fn from_static(value: &'static str) -> Self {
        Self {
            data: value.as_ptr(),
            len: u64::try_from(value.len()).unwrap_or(u64::MAX),
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxExperienceAuthorizationKey {
    pub struct_size: u32,
    pub key_id: NuxByteView,
    /// Exactly 32 raw Ed25519 public-key bytes.
    pub ed25519_public_key: NuxByteView,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
/// One element of `NuxExperienceImportRequest.external_assets`. Because the
/// array has no independent stride, every element must use this exact
/// published size.
pub struct NuxExperienceExternalAsset {
    pub struct_size: u32,
    pub kind: NuxExperienceExternalAssetKind,
    /// Serialized `FileAsset.assetId`, not an asset-list ordinal.
    pub asset_id: u32,
    pub required: bool,
    /// Distinguishes explicitly omitted optional content from supplied empty bytes.
    pub provided: bool,
    pub unique_name: NuxByteView,
    pub source_key: NuxByteView,
    pub expected_sha256: NuxByteView,
    /// Supplied encoded bytes. Image content is decoded during trusted import
    /// and must fit the Apple-safe 8,192-pixel/64-MiB decoded-image limits.
    /// Invalid required images abort import; invalid optional images are
    /// omitted with a structured warning.
    pub bytes: NuxByteView,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
/// Complete package-import request. `struct_size` must equal this published
/// layout's exact size.
pub struct NuxExperienceImportRequest {
    pub struct_size: u32,
    /// The complete `.nux` package bytes.
    pub package_bytes: NuxByteView,
    /// NUL-terminated UTF-8 acquisition identity used to prevent
    /// cross-experience replay.
    pub expected_experience_id: *const c_char,
    /// NUL-terminated UTF-8 acquisition build identity.
    pub expected_build_id: *const c_char,
    /// Candidate public keys used to verify the package signature.
    pub candidate_keys: *const NuxExperienceAuthorizationKey,
    pub candidate_key_count: u64,
    /// Host-resolved external assets. Embedded assets are not included.
    pub external_assets: *const NuxExperienceExternalAsset,
    pub external_asset_count: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
/// Structured diagnostic output layout. Callers initialize `struct_size` to
/// the exact published size before invoking an accessor.
pub struct NuxDiagnosticView {
    pub struct_size: u32,
    pub severity: NuxDiagnosticSeverity,
    pub code: NuxByteView,
    pub message: NuxByteView,
}

impl Default for NuxDiagnosticView {
    fn default() -> Self {
        Self {
            struct_size: size_u32::<Self>(),
            severity: NUX_DIAGNOSTIC_SEVERITY_DEBUG,
            code: NuxByteView::default(),
            message: NuxByteView::default(),
        }
    }
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxScreenSessionDescriptor {
    pub struct_size: u32,
    /// UTF-8 authored artboard name. A null view selects the default artboard.
    pub artboard_name: NuxByteView,
    /// UTF-8 authored state-machine name. A null view uses the shared authored
    /// fallback policy: default state machine, state-machine zero, linear
    /// animation zero, then a static artboard.
    pub state_machine_name: NuxByteView,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxAppleSurfaceDescriptor {
    pub struct_size: u32,
    pub pixel_width: u32,
    pub pixel_height: u32,
}

/// Called exactly once when Metal has finished using a submitted drawable, or
/// before `nux_screen_session_advance` returns when it cannot be submitted.
pub type NuxFrameCompletionCallback = unsafe extern "C" fn(context: *mut c_void);

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct NuxFrameOperation {
    pub struct_size: u32,
    pub elapsed_seconds: f32,
    pub render: bool,
    /// A live `id<CAMetalDrawable>` acquired by Swift on the main actor.
    /// The runtime borrows it only for the synchronous advance call.
    pub apple_drawable: *mut c_void,
    /// Caller-owned context consumed by `completion_callback`. Both completion
    /// fields must be null or non-null together.
    pub completion_context: *mut c_void,
    /// Optional one-shot GPU completion callback. The callback may run on an
    /// arbitrary Metal or runtime thread and must not call UIKit.
    pub completion_callback: Option<unsafe extern "C" fn(context: *mut c_void)>,
}

#[cfg(feature = "apple-product")]
struct PendingFrameCompletion {
    callback: Option<NuxFrameCompletionCallback>,
    context_identity: usize,
}

#[cfg(feature = "apple-product")]
impl PendingFrameCompletion {
    fn from_operation(operation: &NuxFrameOperation) -> Result<Self, &'static str> {
        if operation.completion_callback.is_some() == operation.completion_context.is_null() {
            return Err("frame completion callback and context must be supplied together");
        }
        Ok(Self {
            callback: operation.completion_callback,
            context_identity: operation.completion_context.expose_provenance(),
        })
    }

    fn into_renderer_completion(mut self) -> Option<ApplePresentationCompletion> {
        let callback = self.callback.take()?;
        let context_identity = self.context_identity;
        Some(ApplePresentationCompletion::new(move || unsafe {
            callback(ptr::with_exposed_provenance_mut(context_identity));
        }))
    }
}

#[cfg(feature = "apple-product")]
impl Drop for PendingFrameCompletion {
    fn drop(&mut self) {
        if let Some(callback) = self.callback.take() {
            unsafe {
                callback(ptr::with_exposed_provenance_mut(self.context_identity));
            }
        }
    }
}

/// Opaque C handle. Its storage is private and retained by child handles.
pub struct NuxExperienceContext {
    _private: [u8; 0],
}

/// Opaque process-static proof that the client and linked runtime have the
/// same exact runtime version and source revision.
pub struct NuxRuntimeBinding {
    _private: [u8; 0],
}

/// Opaque C handle. It retains its runtime context.
pub struct NuxScreenSession {
    _private: [u8; 0],
}

/// Opaque C handle. It retains the logical render session across detach.
pub struct NuxAppleSurface {
    _private: [u8; 0],
}

#[cfg(feature = "apple-product")]
type SessionId = u64;

#[cfg(feature = "apple-product")]
type SurfaceId = u64;

#[cfg(feature = "apple-product")]
struct RuntimeWorker {
    sender: Sender<WorkerMessage>,
    join_handle: Mutex<Option<JoinHandle<()>>>,
    thread_id: ThreadId,
}

#[cfg(feature = "apple-product")]
struct ExperienceRuntimeContextHandle {
    worker: Arc<RuntimeWorker>,
}

#[cfg(feature = "apple-product")]
struct SessionToken {
    worker: Arc<RuntimeWorker>,
    id: SessionId,
}

#[cfg(feature = "apple-product")]
struct ScreenSessionHandle {
    token: Arc<SessionToken>,
}

#[cfg(feature = "apple-product")]
struct SurfaceToken {
    session: Arc<SessionToken>,
    id: SurfaceId,
}

#[cfg(feature = "apple-product")]
struct AppleSurfaceHandle {
    token: Arc<SurfaceToken>,
}

#[cfg(feature = "apple-product")]
struct WorkerState {
    owner_thread_id: ThreadId,
    file: Arc<File>,
    shared_gpu_factory: Option<WgpuFactory>,
    gpu_generation: u64,
    sessions: HashMap<SessionId, SessionState>,
    next_session_id: SessionId,
    next_surface_id: SurfaceId,
}

#[cfg(feature = "apple-product")]
struct SessionState {
    is_fatal: bool,
    fatal_diagnostic: Option<String>,
    screen_session: FlowSession,
    // A stable address is part of the script renderer-domain contract. The
    // factory belongs to the logical session, not to its optional surface.
    factory: Box<WgpuFactory>,
    renderer_generation: u64,
    legacy_timestamp_seconds: f64,
    #[cfg(test)]
    render_attempts: usize,
    #[cfg(test)]
    injected_device_loss: bool,
    #[cfg(test)]
    panic_on_next_configured_operation: bool,
    attachment: Option<SurfaceState>,
}

#[cfg(feature = "apple-product")]
struct SurfaceState {
    id: SurfaceId,
    surface: AppleSurface,
}

#[cfg(feature = "apple-product")]
impl SessionState {
    fn terminalize(&mut self, diagnostic: impl Into<String>) {
        self.is_fatal = true;
        self.fatal_diagnostic = Some(diagnostic.into());
    }

    fn preflight_present(
        &self,
        drawable_available: bool,
    ) -> Result<Option<SurfaceDisposition>, RuntimeFailure> {
        let attachment = self
            .attachment
            .as_ref()
            .ok_or_else(|| RuntimeFailure::surface("surface is not attached"))?;
        #[cfg(test)]
        if self.injected_device_loss {
            return Ok(Some(SurfaceDisposition::DeviceLost));
        }
        attachment
            .surface
            .preflight_present(&self.factory, drawable_available)
            .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))
    }

    fn requires_device_recovery(&self) -> bool {
        #[cfg(test)]
        if self.injected_device_loss {
            return true;
        }
        self.factory.device_is_lost()
    }
}

#[cfg(feature = "apple-product")]
fn terminalize_after_committed_advance_failure(
    session: &mut SessionState,
    phase: &str,
    failure: RuntimeFailure,
) -> RuntimeFailure {
    session.terminalize(format!(
        "screen session is terminal after a committed advance failed during {phase}: {}",
        failure.diagnostic
    ));
    failure
}

#[cfg(feature = "apple-product")]
struct WorkerJob {
    session_id: Option<SessionId>,
    execute: Box<dyn FnOnce(&mut WorkerState) + Send + 'static>,
    on_panic: Box<dyn FnOnce() + Send + 'static>,
}

#[cfg(feature = "apple-product")]
enum WorkerMessage {
    Run(WorkerJob),
    Shutdown,
}

#[cfg(feature = "apple-product")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WorkerCallError {
    Panicked,
    Unavailable,
}

#[cfg(feature = "apple-product")]
enum WorkerStartError {
    Import { code: String, message: String },
    Runtime(String),
    Panicked,
}

#[cfg(feature = "apple-product")]
struct RuntimeImportDiagnostic {
    severity: NuxDiagnosticSeverity,
    code: String,
    message: String,
}

#[cfg(feature = "apple-product")]
struct RuntimeImportMetadata {
    authenticated_key_id: String,
    diagnostics: Vec<RuntimeImportDiagnostic>,
}

#[cfg(feature = "apple-product")]
struct WorkerInitialization {
    thread_id: ThreadId,
    metadata: RuntimeImportMetadata,
}

#[cfg(feature = "apple-product")]
fn import_runtime_input(
    input: ExperiencePackageImportInput,
) -> Result<(File, RuntimeImportMetadata), WorkerStartError> {
    let validated =
        validate_experience_package_import(input).map_err(|error| WorkerStartError::Import {
            code: error.code.to_owned(),
            message: error.message,
        })?;
    let mut file = validated.file;
    let mut diagnostics = validated
        .diagnostics
        .into_iter()
        .map(|diagnostic| RuntimeImportDiagnostic {
            severity: match diagnostic.severity {
                PackageDiagnosticSeverity::Warning => NUX_DIAGNOSTIC_SEVERITY_WARNING,
            },
            code: diagnostic.code.to_owned(),
            message: diagnostic.message,
        })
        .collect::<Vec<_>>();
    for asset in validated.external_assets {
        let Some(bytes) = asset.bytes else {
            continue;
        };
        let kind_label = match asset.kind {
            ExternalAssetKind::Image => "image",
            ExternalAssetKind::Font => "font",
        };
        let attachment: Result<(), String> = match asset.kind {
            ExternalAssetKind::Image => WgpuFactory::validate_image_bytes(&bytes)
                .map_err(|error| error.to_string())
                .and_then(|()| {
                    file.attach_external_image_asset_bytes(asset.asset_id, bytes)
                        .map_err(|error| error.to_string())
                }),
            ExternalAssetKind::Font => file
                .attach_external_font_asset_bytes(asset.asset_id, bytes)
                .map_err(|error| error.to_string()),
        };
        if let Err(error) = attachment {
            if !asset.required {
                diagnostics.push(RuntimeImportDiagnostic {
                    severity: NUX_DIAGNOSTIC_SEVERITY_WARNING,
                    code: "package.asset.optional_invalid".to_owned(),
                    message: format!(
                        "optional {kind_label} asset {} '{}' could not be decoded or attached: {error}",
                        asset.asset_id, asset.unique_name
                    ),
                });
                continue;
            }
            return Err(WorkerStartError::Import {
                code: "package.asset_table.mismatch".to_owned(),
                message: format!(
                    "asset {} '{}' could not be attached: {error}",
                    asset.asset_id, asset.unique_name
                ),
            });
        }
    }
    Ok((
        file,
        RuntimeImportMetadata {
            authenticated_key_id: validated.authenticated_key_id,
            diagnostics,
        },
    ))
}

#[cfg(feature = "apple-product")]
#[derive(Debug)]
struct RuntimeFailure {
    status: NuxStatus,
    diagnostic_code: &'static [u8],
    diagnostic: String,
}

#[cfg(feature = "apple-product")]
impl RuntimeFailure {
    fn new(status: NuxStatus, diagnostic: impl Into<String>) -> Self {
        Self::with_code(status, diagnostic_code_for_status(status), diagnostic)
    }

    fn with_code(
        status: NuxStatus,
        diagnostic_code: &'static [u8],
        diagnostic: impl Into<String>,
    ) -> Self {
        Self {
            status,
            diagnostic_code,
            diagnostic: diagnostic.into(),
        }
    }

    fn screen_session(kind: FlowSessionErrorKind, diagnostic: impl Into<String>) -> Self {
        let (status, diagnostic_code) = match kind {
            FlowSessionErrorKind::NotFound => (
                NuxStatus::NotFound,
                diagnostic_code_for_status(NuxStatus::NotFound),
            ),
            FlowSessionErrorKind::InvalidArgument
            | FlowSessionErrorKind::LimitExceeded
            | FlowSessionErrorKind::Conflict => (
                NuxStatus::InvalidArgument,
                diagnostic_code_for_status(NuxStatus::InvalidArgument),
            ),
            FlowSessionErrorKind::ResultLimitExceeded => {
                (NuxStatus::RuntimeError, RESULT_LIMIT_DIAGNOSTIC_CODE)
            }
            FlowSessionErrorKind::ScriptResourceExceeded => {
                (NuxStatus::RuntimeError, SCRIPT_RESOURCE_DIAGNOSTIC_CODE)
            }
            FlowSessionErrorKind::Runtime => (
                NuxStatus::RuntimeError,
                diagnostic_code_for_status(NuxStatus::RuntimeError),
            ),
        };
        Self::with_code(status, diagnostic_code, diagnostic)
    }

    fn runtime(diagnostic: impl Into<String>) -> Self {
        Self::new(NuxStatus::RuntimeError, diagnostic)
    }

    fn surface(diagnostic: impl Into<String>) -> Self {
        Self::new(NuxStatus::SurfaceError, diagnostic)
    }
}

#[cfg(feature = "apple-product")]
fn runtime_failure_from_screen_session(
    error: nuxie::flow_session::FlowSessionError,
) -> RuntimeFailure {
    RuntimeFailure::screen_session(error.kind(), error.message())
}

#[cfg(feature = "apple-product")]
impl WorkerState {
    // Script-enabled Files are intentionally confined to this worker thread.
    // `Arc` provides same-thread shared ownership to its sessions; neither the
    // File nor its Luau VM crosses the worker boundary.
    #[allow(clippy::arc_with_non_send_sync)]
    fn new(file: File) -> Self {
        Self {
            owner_thread_id: thread::current().id(),
            file: Arc::new(file),
            shared_gpu_factory: None,
            gpu_generation: 0,
            sessions: HashMap::new(),
            next_session_id: 1,
            next_surface_id: 1,
        }
    }

    fn allocate_session_id(&mut self) -> Result<SessionId, RuntimeFailure> {
        let id = self.next_session_id;
        self.next_session_id = self
            .next_session_id
            .checked_add(1)
            .ok_or_else(|| RuntimeFailure::runtime("session identifier space is exhausted"))?;
        Ok(id)
    }

    fn allocate_surface_id(&mut self) -> Result<SurfaceId, RuntimeFailure> {
        let id = self.next_surface_id;
        self.next_surface_id = self
            .next_surface_id
            .checked_add(1)
            .ok_or_else(|| RuntimeFailure::runtime("surface identifier space is exhausted"))?;
        Ok(id)
    }

    fn create_session(
        &mut self,
        artboard_name: Option<String>,
        state_machine_name: Option<String>,
    ) -> Result<SessionId, RuntimeFailure> {
        let mut factory = self.make_session_factory()?;
        let renderer_generation = self.gpu_generation;
        let (screen_session, _) = FlowSession::create_with_factory(
            Arc::clone(&self.file),
            FlowSessionConfig {
                artboard_name,
                player: state_machine_name.map(FlowPlayerSelector::StateMachine),
            },
            factory.as_mut(),
        )
        .map_err(runtime_failure_from_screen_session)?;
        let id = self.allocate_session_id()?;
        self.sessions.insert(
            id,
            SessionState {
                is_fatal: false,
                fatal_diagnostic: None,
                screen_session,
                factory,
                renderer_generation,
                legacy_timestamp_seconds: 0.0,
                #[cfg(test)]
                render_attempts: 0,
                #[cfg(test)]
                injected_device_loss: false,
                #[cfg(test)]
                panic_on_next_configured_operation: false,
                attachment: None,
            },
        );
        Ok(id)
    }

    fn session(&self, id: SessionId) -> Result<&SessionState, RuntimeFailure> {
        self.sessions
            .get(&id)
            .ok_or_else(|| RuntimeFailure::runtime("render session is unavailable"))
    }

    fn session_mut(&mut self, id: SessionId) -> Result<&mut SessionState, RuntimeFailure> {
        self.sessions
            .get_mut(&id)
            .ok_or_else(|| RuntimeFailure::runtime("render session is unavailable"))
    }

    fn require_live_session(&self, id: SessionId) -> Result<(), RuntimeFailure> {
        let session = self.session(id)?;
        if session.is_fatal {
            Err(RuntimeFailure::runtime(
                session
                    .fatal_diagnostic
                    .as_deref()
                    .unwrap_or(PANIC_DIAGNOSTIC),
            ))
        } else {
            Ok(())
        }
    }

    fn make_session_factory(&mut self) -> Result<Box<WgpuFactory>, RuntimeFailure> {
        if self.shared_gpu_factory.is_none() {
            let factory = WgpuFactory::new_with_mode(1, 1, RenderMode::Msaa)
                .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))?;
            let generation = self
                .gpu_generation
                .checked_add(1)
                .ok_or_else(|| RuntimeFailure::surface("GPU generation space is exhausted"))?;
            self.shared_gpu_factory = Some(factory);
            self.gpu_generation = generation;
        }
        let Some(factory) = self.shared_gpu_factory.as_ref() else {
            return Err(RuntimeFailure::surface(
                "shared GPU factory initialization produced no factory",
            ));
        };
        let factory = factory
            .new_session_factory(1, 1, RenderMode::Msaa)
            .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))?;
        Ok(Box::new(factory))
    }

    fn attach_surface(
        &mut self,
        session_id: SessionId,
        width: u32,
        height: u32,
    ) -> Result<SurfaceId, RuntimeFailure> {
        self.require_live_session(session_id)?;
        if self.session(session_id)?.attachment.is_some() {
            return Err(RuntimeFailure::new(
                NuxStatus::InvalidArgument,
                "session already has an attached surface",
            ));
        }
        let id = self.allocate_surface_id()?;
        let session = self.session_mut(session_id)?;
        let surface = AppleSurface::attach(&mut session.factory, width, height)
            .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))?;
        self.session_mut(session_id)?.attachment = Some(SurfaceState { id, surface });
        Ok(id)
    }

    fn session_surface_mut(
        &mut self,
        session_id: SessionId,
        surface_id: SurfaceId,
    ) -> Result<(&mut WgpuFactory, &mut SurfaceState), RuntimeFailure> {
        self.require_live_session(session_id)?;
        let session = self.session_mut(session_id)?;
        let attachment = session
            .attachment
            .as_mut()
            .filter(|attachment| attachment.id == surface_id)
            .ok_or_else(|| RuntimeFailure::surface("surface is detached"))?;
        Ok((session.factory.as_mut(), attachment))
    }

    fn reattach_surface(
        &mut self,
        session_id: SessionId,
        surface_id: SurfaceId,
        width: u32,
        height: u32,
    ) -> Result<SurfaceDisposition, RuntimeFailure> {
        self.require_live_session(session_id)?;
        let session = self.session(session_id)?;
        if session
            .attachment
            .as_ref()
            .is_none_or(|attachment| attachment.id != surface_id)
        {
            return Err(RuntimeFailure::surface("surface is detached"));
        }
        if !session.requires_device_recovery() {
            let (factory, attachment) = self.session_surface_mut(session_id, surface_id)?;
            return attachment
                .surface
                .reattach(factory, width, height)
                .map_err(|error| RuntimeFailure::surface(format!("{error:#}")));
        }

        // A real device-loss notification is shared by the base factory and
        // all derived session factories. The test-only loss seam is scoped to
        // one session, but still forces the same base-domain replacement so it
        // proves the production transaction without exposing a fault control.
        #[cfg(test)]
        let force_base_replacement = session.injected_device_loss;
        #[cfg(not(test))]
        let force_base_replacement = false;
        let replace_base = force_base_replacement
            || self
                .shared_gpu_factory
                .as_ref()
                .is_none_or(WgpuFactory::device_is_lost);
        let candidate_base = if replace_base {
            Some(
                WgpuFactory::new_with_mode(1, 1, RenderMode::Msaa)
                    .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))?,
            )
        } else {
            None
        };
        let base = candidate_base
            .as_ref()
            .or(self.shared_gpu_factory.as_ref())
            .ok_or_else(|| {
                RuntimeFailure::surface("shared GPU factory recovery produced no factory")
            })?;
        let mut candidate_factory = base
            .new_session_factory(width.max(1), height.max(1), RenderMode::Msaa)
            .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))?;
        let candidate_surface = AppleSurface::attach(&mut candidate_factory, width, height)
            .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))?;
        let candidate_generation = if candidate_base.is_some() {
            self.gpu_generation
                .checked_add(1)
                .ok_or_else(|| RuntimeFailure::surface("GPU generation space is exhausted"))?
        } else {
            self.gpu_generation
        };

        // Commit only after the complete replacement graph exists. Assigning
        // through the Box keeps the exact live Factory address that scripts
        // bind as their renderer domain while dropping every old GPU handle.
        let WorkerState {
            shared_gpu_factory,
            gpu_generation,
            sessions,
            ..
        } = self;
        let session = sessions
            .get_mut(&session_id)
            .ok_or_else(|| RuntimeFailure::runtime("render session is unavailable"))?;
        let attachment = session
            .attachment
            .as_mut()
            .filter(|attachment| attachment.id == surface_id)
            .ok_or_else(|| RuntimeFailure::surface("surface is detached"))?;
        if let Some(candidate_base) = candidate_base {
            *shared_gpu_factory = Some(candidate_base);
            *gpu_generation = candidate_generation;
        }
        *session.factory = candidate_factory;
        session.renderer_generation = candidate_generation;
        session.screen_session.reset_renderer();
        attachment.surface = candidate_surface;
        #[cfg(test)]
        {
            session.injected_device_loss = false;
        }
        Ok(if width == 0 || height == 0 {
            SurfaceDisposition::SkippedZeroSize
        } else {
            SurfaceDisposition::Recreated
        })
    }

    fn remove_surface(&mut self, session_id: SessionId, surface_id: SurfaceId) {
        let Some(session) = self.sessions.get_mut(&session_id) else {
            return;
        };
        let is_current = session
            .attachment
            .as_ref()
            .is_some_and(|attachment| attachment.id == surface_id);
        if !is_current {
            return;
        }
        if let Some(mut attachment) = session.attachment.take() {
            attachment.surface.detach();
        }
    }

    fn remove_session(&mut self, session_id: SessionId) {
        if let Some(mut session) = self.sessions.remove(&session_id)
            && let Some(mut attachment) = session.attachment.take()
        {
            attachment.surface.detach();
        }
    }

    fn poison_session(&mut self, session_id: SessionId) {
        if let Some(session) = self.sessions.get_mut(&session_id) {
            session.terminalize(PANIC_DIAGNOSTIC);
        }
    }
}

#[cfg(feature = "apple-product")]
fn centered_contain_transform(
    artboard_x: f32,
    artboard_y: f32,
    artboard_width: f32,
    artboard_height: f32,
    viewport_width: u32,
    viewport_height: u32,
) -> Result<Mat2D, RuntimeFailure> {
    if !artboard_x.is_finite()
        || !artboard_y.is_finite()
        || !artboard_width.is_finite()
        || !artboard_height.is_finite()
        || artboard_width <= 0.0
        || artboard_height <= 0.0
        || viewport_width == 0
        || viewport_height == 0
    {
        return Err(RuntimeFailure::runtime(
            "artboard and viewport dimensions must be finite and positive",
        ));
    }
    let viewport_width = viewport_width as f32;
    let viewport_height = viewport_height as f32;
    let scale = (viewport_width / artboard_width).min(viewport_height / artboard_height);
    let offset_x = (viewport_width - artboard_width * scale) * 0.5 - artboard_x * scale;
    let offset_y = (viewport_height - artboard_height * scale) * 0.5 - artboard_y * scale;
    if !scale.is_finite() || !offset_x.is_finite() || !offset_y.is_finite() || scale <= 0.0 {
        return Err(RuntimeFailure::runtime(
            "centered contain transform is not finite",
        ));
    }
    Ok(Mat2D([scale, 0.0, 0.0, scale, offset_x, offset_y]))
}

#[cfg(feature = "apple-product")]
impl Drop for WorkerState {
    fn drop(&mut self) {
        debug_assert_eq!(thread::current().id(), self.owner_thread_id);
    }
}

#[cfg(feature = "apple-product")]
impl RuntimeWorker {
    #[cfg(test)]
    fn spawn(scene_bytes: Vec<u8>) -> Result<Arc<Self>, WorkerStartError> {
        Self::spawn_with_initializer(move || {
            let file = File::import(&scene_bytes)
                .map_err(|error| WorkerStartError::Runtime(error.to_string()))?;
            Ok((
                file,
                RuntimeImportMetadata {
                    authenticated_key_id: String::new(),
                    diagnostics: Vec::new(),
                },
            ))
        })
        .map(|(worker, _)| worker)
    }

    fn spawn_input(
        input: ExperiencePackageImportInput,
    ) -> Result<(Arc<Self>, RuntimeImportMetadata), WorkerStartError> {
        Self::spawn_with_initializer(move || import_runtime_input(input))
    }

    fn spawn_with_initializer(
        initializer: impl FnOnce() -> Result<(File, RuntimeImportMetadata), WorkerStartError>
        + Send
        + 'static,
    ) -> Result<(Arc<Self>, RuntimeImportMetadata), WorkerStartError> {
        let (sender, receiver) = mpsc::channel();
        let (initialization_sender, initialization_receiver) = mpsc::sync_channel(1);
        let join_handle = thread::Builder::new()
            .name("nuxie-experience-runtime".to_owned())
            .spawn(move || {
                let state = panic::catch_unwind(AssertUnwindSafe(|| {
                    initializer().map(|(file, metadata)| (WorkerState::new(file), metadata))
                }));
                let (state, metadata) = match state {
                    Ok(Ok(initialized)) => initialized,
                    Ok(Err(error)) => {
                        let _ = initialization_sender.send(Err(error));
                        return;
                    }
                    Err(_) => {
                        let _ = initialization_sender.send(Err(WorkerStartError::Panicked));
                        return;
                    }
                };
                let _ = initialization_sender.send(Ok(WorkerInitialization {
                    thread_id: thread::current().id(),
                    metadata,
                }));
                worker_loop(state, receiver);
            })
            .map_err(|error| WorkerStartError::Runtime(error.to_string()))?;

        let initialization = initialization_receiver.recv().map_err(|_| {
            WorkerStartError::Runtime("runtime worker stopped during initialization".to_owned())
        });
        let initialization = match initialization {
            Ok(Ok(initialization)) => initialization,
            Ok(Err(error)) => {
                let _ = join_handle.join();
                return Err(error);
            }
            Err(error) => {
                let _ = join_handle.join();
                return Err(error);
            }
        };
        Ok((
            Arc::new(Self {
                sender,
                join_handle: Mutex::new(Some(join_handle)),
                thread_id: initialization.thread_id,
            }),
            initialization.metadata,
        ))
    }

    fn call<R: Send + 'static>(
        &self,
        session_id: Option<SessionId>,
        body: impl FnOnce(&mut WorkerState) -> R + Send + 'static,
    ) -> Result<R, WorkerCallError> {
        if thread::current().id() == self.thread_id {
            return Err(WorkerCallError::Unavailable);
        }
        let (response_sender, response_receiver) = mpsc::sync_channel(1);
        let panic_sender = response_sender.clone();
        let job = WorkerJob {
            session_id,
            execute: Box::new(move |state| {
                let response = body(state);
                let _ = response_sender.send(Ok(response));
            }),
            on_panic: Box::new(move || {
                let _ = panic_sender.send(Err(WorkerCallError::Panicked));
            }),
        };
        self.sender
            .send(WorkerMessage::Run(job))
            .map_err(|_| WorkerCallError::Unavailable)?;
        response_receiver
            .recv()
            .map_err(|_| WorkerCallError::Unavailable)?
    }

    fn poison_session(&self, session_id: SessionId) {
        let _ = self.call(None, move |state| state.poison_session(session_id));
    }

    #[cfg(test)]
    fn probe_thread_id(&self) -> Result<ThreadId, WorkerCallError> {
        self.call(None, |_| thread::current().id())
    }
}

#[cfg(feature = "apple-product")]
impl Drop for RuntimeWorker {
    fn drop(&mut self) {
        let _ = self.sender.send(WorkerMessage::Shutdown);
        let join_handle = match self.join_handle.get_mut() {
            Ok(join_handle) => join_handle.take(),
            Err(poisoned) => poisoned.into_inner().take(),
        };
        if let Some(join_handle) = join_handle
            && thread::current().id() != self.thread_id
        {
            let _ = join_handle.join();
        }
    }
}

#[cfg(feature = "apple-product")]
impl Drop for SessionToken {
    fn drop(&mut self) {
        let session_id = self.id;
        // Swift enqueues C destruction away from the main actor. Complete the
        // worker-side teardown before returning so GPU resources are gone
        // before the final Swift owner is released.
        let _ = self
            .worker
            .call(None, move |state| state.remove_session(session_id));
    }
}

#[cfg(feature = "apple-product")]
impl Drop for SurfaceToken {
    fn drop(&mut self) {
        let session_id = self.session.id;
        let surface_id = self.id;
        let _ = self.session.worker.call(Some(session_id), move |state| {
            state.remove_surface(session_id, surface_id);
        });
    }
}

#[cfg(feature = "apple-product")]
fn worker_loop(mut state: WorkerState, receiver: Receiver<WorkerMessage>) {
    while let Ok(message) = receiver.recv() {
        let WorkerMessage::Run(job) = message else {
            break;
        };
        debug_assert_eq!(thread::current().id(), state.owner_thread_id);
        let WorkerJob {
            session_id,
            execute,
            on_panic,
        } = job;
        if panic::catch_unwind(AssertUnwindSafe(|| execute(&mut state))).is_err() {
            if let Some(session_id) = session_id {
                state.poison_session(session_id);
            }
            let _ = panic::catch_unwind(AssertUnwindSafe(on_panic));
        }
    }
}

#[cfg(feature = "apple-product")]
#[allow(dead_code)]
fn assert_opaque_handle_storage_is_send_and_sync() {
    fn assert_send_and_sync<T: Send + Sync>() {}
    assert_send_and_sync::<ExperienceRuntimeContextHandle>();
    assert_send_and_sync::<ScreenSessionHandle>();
    assert_send_and_sync::<AppleSurfaceHandle>();
}

#[derive(Clone)]
struct OwnedDiagnostic {
    severity: NuxDiagnosticSeverity,
    code: Vec<u8>,
    message: Vec<u8>,
}

pub struct NuxOperationResult {
    status: NuxStatus,
    surface_disposition: NuxSurfaceDisposition,
    changed: bool,
    authenticated_key_id: Vec<u8>,
    diagnostics: Vec<OwnedDiagnostic>,
    // Scalar compatibility view: the first structured diagnostic message.
    diagnostic: Vec<u8>,
}

impl NuxOperationResult {
    fn success(surface_disposition: NuxSurfaceDisposition, changed: bool) -> Self {
        Self {
            status: NuxStatus::Ok,
            surface_disposition,
            changed,
            authenticated_key_id: Vec::new(),
            diagnostics: Vec::new(),
            diagnostic: Vec::new(),
        }
    }

    #[cfg(feature = "apple-product")]
    fn import_success(metadata: RuntimeImportMetadata) -> Self {
        let diagnostics = metadata
            .diagnostics
            .into_iter()
            .map(|diagnostic| OwnedDiagnostic {
                severity: diagnostic.severity,
                code: diagnostic.code.into_bytes(),
                message: diagnostic.message.into_bytes(),
            })
            .collect::<Vec<_>>();
        let diagnostic = diagnostics
            .first()
            .map(|diagnostic| diagnostic.message.clone())
            .unwrap_or_default();
        Self {
            status: NuxStatus::Ok,
            surface_disposition: NuxSurfaceDisposition::None,
            changed: false,
            authenticated_key_id: metadata.authenticated_key_id.into_bytes(),
            diagnostics,
            diagnostic,
        }
    }

    fn failure(status: NuxStatus, diagnostic: impl Into<Vec<u8>>) -> Self {
        Self::failure_with_code(status, diagnostic_code_for_status(status), diagnostic)
    }

    fn failure_with_code(
        status: NuxStatus,
        code: impl Into<Vec<u8>>,
        diagnostic: impl Into<Vec<u8>>,
    ) -> Self {
        let diagnostic = diagnostic.into();
        Self {
            status,
            surface_disposition: NuxSurfaceDisposition::Fatal,
            changed: false,
            authenticated_key_id: Vec::new(),
            diagnostics: vec![OwnedDiagnostic {
                severity: NUX_DIAGNOSTIC_SEVERITY_FATAL,
                code: code.into(),
                message: diagnostic.clone(),
            }],
            diagnostic,
        }
    }

    fn import_failure(
        status: NuxStatus,
        code: impl Into<Vec<u8>>,
        message: impl Into<Vec<u8>>,
    ) -> Self {
        let message = message.into();
        Self {
            status,
            surface_disposition: NuxSurfaceDisposition::Fatal,
            changed: false,
            authenticated_key_id: Vec::new(),
            diagnostics: vec![OwnedDiagnostic {
                severity: NUX_DIAGNOSTIC_SEVERITY_FATAL,
                code: code.into(),
                message: message.clone(),
            }],
            diagnostic: message,
        }
    }
}

fn diagnostic_code_for_status(status: NuxStatus) -> &'static [u8] {
    match status {
        NUX_STATUS_OK => b"nux_runtime.ok",
        NUX_STATUS_NULL_ARGUMENT => b"nux_runtime.null_argument",
        NUX_STATUS_IMPORT_ERROR => b"nux_runtime.import_error",
        NUX_STATUS_NOT_FOUND => b"nux_runtime.not_found",
        NUX_STATUS_RUNTIME_ERROR => b"nux_runtime.runtime_error",
        NUX_STATUS_INVALID_ARGUMENT => b"nux_runtime.invalid_argument",
        NUX_STATUS_RUNTIME_IDENTITY_MISMATCH => b"nux_runtime.runtime_identity_mismatch",
        NUX_STATUS_SURFACE_ERROR => b"nux_runtime.surface_error",
        _ => b"nux_runtime.unknown",
    }
}

fn runtime_binding() -> *const NuxRuntimeBinding {
    ptr::from_ref(&RUNTIME_BINDING_TOKEN).cast()
}

unsafe fn runtime_identity_part_matches(
    data: *const u8,
    len: u64,
    expected: &[u8],
) -> Result<bool, NuxStatus> {
    let len = usize::try_from(len).map_err(|_| NuxStatus::InvalidArgument)?;
    if len == 0 || len > MAX_RUNTIME_IDENTITY_PART_BYTE_LENGTH || len > isize::MAX as usize {
        return Err(NuxStatus::InvalidArgument);
    }
    if data.is_null() {
        return Err(NuxStatus::InvalidArgument);
    }
    let bytes = unsafe { slice::from_raw_parts(data, len) };
    std::str::from_utf8(bytes).map_err(|_| NuxStatus::InvalidArgument)?;
    Ok(bytes == expected)
}

#[unsafe(no_mangle)]
/// Binds a client compiled for one exact runtime version and source revision
/// to this linked runtime. The returned proof is process-static.
///
/// # Safety
///
/// Non-null identity pointers must be readable for their declared lengths.
/// `out_binding` must point to writable, properly aligned pointer storage.
pub unsafe extern "C" fn nux_runtime_bind(
    expected_runtime_version: *const u8,
    expected_runtime_version_len: u64,
    expected_source_revision: *const u8,
    expected_source_revision_len: u64,
    out_binding: *mut *const NuxRuntimeBinding,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_binding.is_null() {
            return NuxStatus::NullArgument;
        }
        unsafe {
            *out_binding = ptr::null();
        }
        let runtime_version_matches = match unsafe {
            runtime_identity_part_matches(
                expected_runtime_version,
                expected_runtime_version_len,
                RUNTIME_VERSION.as_bytes(),
            )
        } {
            Ok(value) => value,
            Err(status) => return status,
        };
        let source_revision_matches = match unsafe {
            runtime_identity_part_matches(
                expected_source_revision,
                expected_source_revision_len,
                SOURCE_REVISION.as_bytes(),
            )
        } {
            Ok(value) => value,
            Err(status) => return status,
        };
        if !runtime_version_matches || !source_revision_matches {
            return NuxStatus::RuntimeIdentityMismatch;
        }
        unsafe {
            *out_binding = runtime_binding();
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Writes a process-static UTF-8 JSON view to `out_provenance`.
///
/// # Safety
///
/// `out_provenance` must point to writable, properly aligned storage for one
/// [`NuxByteView`].
pub unsafe extern "C" fn nux_runtime_build_provenance(
    out_provenance: *mut NuxByteView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_provenance.is_null() {
            return NuxStatus::NullArgument;
        }
        unsafe {
            *out_provenance = NuxByteView::from_static(BUILD_PROVENANCE);
        }
        NuxStatus::Ok
    })
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Imports one signed `.nux` package into a retained experience context.
///
/// This convenience entry binds against the linked runtime automatically.
///
/// # Safety
///
/// Non-null pointers must be properly aligned and valid for this call. Package
/// and nested request views must remain readable through the call. Identity
/// pointers must name readable NUL-terminated UTF-8 strings. Output pointers
/// must address writable handle storage.
pub unsafe extern "C" fn nux_experience_context_create(
    request: *const NuxExperienceImportRequest,
    out_context: *mut *mut NuxExperienceContext,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || {},
        || unsafe {
            nux_experience_context_create_bound(runtime_binding(), request, out_context, out_result)
        },
    )
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Imports one signed `.nux` package through an exact runtime binding.
///
/// # Safety
///
/// Non-null pointers must be properly aligned and valid for this call. Package
/// and nested request views must remain readable through the call. Identity
/// pointers must name readable NUL-terminated UTF-8 strings. Output pointers
/// must address writable handle storage.
pub unsafe extern "C" fn nux_experience_context_create_bound(
    binding: *const NuxRuntimeBinding,
    request: *const NuxExperienceImportRequest,
    out_context: *mut *mut NuxExperienceContext,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || {},
        || {
            reset_out_handle(out_context);
            reset_out_handle(out_result);
            if out_context.is_null() {
                return NuxStatus::NullArgument;
            }
            if binding.is_null() {
                return NuxStatus::NullArgument;
            }
            if binding != runtime_binding() {
                return write_import_failure(
                    out_result,
                    NuxStatus::RuntimeIdentityMismatch,
                    "nux_runtime.runtime_identity_mismatch",
                    "runtime binding does not match the linked runtime",
                );
            }
            if request.is_null() {
                return NuxStatus::NullArgument;
            }
            let input = match unsafe { copy_experience_import_input(request) } {
                Ok(input) => input,
                Err(error) => {
                    return write_import_failure(
                        out_result,
                        error.status,
                        error.code,
                        error.message,
                    );
                }
            };
            match RuntimeWorker::spawn_input(input) {
                Ok((worker, metadata)) => {
                    let context = Box::new(ExperienceRuntimeContextHandle { worker });
                    unsafe {
                        *out_context = Box::into_raw(context).cast();
                    }
                    replace_result(out_result, NuxOperationResult::import_success(metadata));
                    NuxStatus::Ok
                }
                Err(WorkerStartError::Import { code, message }) => {
                    write_import_failure(out_result, NuxStatus::ImportError, code, message)
                }
                Err(WorkerStartError::Runtime(diagnostic)) => {
                    write_failure(out_result, NuxStatus::RuntimeError, diagnostic)
                }
                Err(WorkerStartError::Panicked) => {
                    write_failure(out_result, NuxStatus::RuntimeError, PANIC_DIAGNOSTIC)
                }
            }
        },
    )
}

#[unsafe(no_mangle)]
/// Releases one experience-context handle. Null is a no-op.
///
/// # Safety
///
/// A non-null pointer must be an owned handle returned by this library and
/// must not have been released before. Release must not race a call using the
/// same handle. Child handles may remain alive.
pub unsafe extern "C" fn nux_experience_context_free(context: *mut NuxExperienceContext) {
    ffi_guard((), || {
        if !context.is_null() {
            unsafe {
                #[cfg(feature = "apple-product")]
                drop(Box::from_raw(
                    context.cast::<ExperienceRuntimeContextHandle>(),
                ));
            }
        }
    })
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Creates an independent logical screen session from a context through the
/// legacy unconfigured surface. Cycle-zero host outputs produced while scripts are
/// initialized are intentionally not returned by this entry point; use
/// `nux_screen_session_create_configured` when those outputs are needed.
///
/// # Safety
///
/// `context` must be live. The descriptor and output pointers must be valid,
/// aligned, and readable or writable as their direction requires. Calls may
/// originate on arbitrary threads; this library serializes runtime state.
pub unsafe extern "C" fn nux_screen_session_create(
    context: *const NuxExperienceContext,
    descriptor: *const NuxScreenSessionDescriptor,
    out_session: *mut *mut NuxScreenSession,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || {},
        || {
            reset_out_handle(out_session);
            reset_out_handle(out_result);
            if context.is_null() || descriptor.is_null() || out_session.is_null() {
                return NuxStatus::NullArgument;
            }
            let context = unsafe { &*context.cast::<ExperienceRuntimeContextHandle>() };
            let struct_size = unsafe { read_struct_size(descriptor) };
            if struct_size != size_u32::<NuxScreenSessionDescriptor>() {
                return write_failure(
                    out_result,
                    NuxStatus::InvalidArgument,
                    "screen session descriptor has the wrong exact size",
                );
            }
            let descriptor = unsafe { *descriptor };
            let artboard_name = match optional_utf8_string(descriptor.artboard_name) {
                Ok(name) => name,
                Err(status) => {
                    return write_failure(out_result, status, "artboard name is not valid UTF-8");
                }
            };
            let state_machine_name = match optional_utf8_string(descriptor.state_machine_name) {
                Ok(name) => name,
                Err(status) => {
                    return write_failure(
                        out_result,
                        status,
                        "state-machine name is not valid UTF-8",
                    );
                }
            };
            let session_id = match context.worker.call(None, move |state| {
                state.create_session(artboard_name, state_machine_name)
            }) {
                Ok(Ok(session_id)) => session_id,
                Ok(Err(failure)) => return write_runtime_failure(out_result, failure),
                Err(error) => return write_worker_call_failure(out_result, error),
            };
            let session = Box::new(ScreenSessionHandle {
                token: Arc::new(SessionToken {
                    worker: Arc::clone(&context.worker),
                    id: session_id,
                }),
            });
            unsafe {
                *out_session = Box::into_raw(session).cast();
            }
            write_success(out_result, NuxSurfaceDisposition::None, false)
        },
    )
}

#[unsafe(no_mangle)]
/// Releases one render-session handle. Null is a no-op.
///
/// # Safety
///
/// A non-null pointer must be an owned handle returned by this library and not
/// previously released. Release must not race a call using the same handle.
/// Child surfaces may remain alive.
pub unsafe extern "C" fn nux_screen_session_free(session: *mut NuxScreenSession) {
    ffi_guard((), || {
        if !session.is_null() {
            unsafe {
                #[cfg(feature = "apple-product")]
                drop(Box::from_raw(session.cast::<ScreenSessionHandle>()));
            }
        }
    })
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Creates logical Apple presentation state for a render session.
///
/// # Safety
///
/// Handles and output pointers must be valid. Calls may originate on arbitrary
/// threads; this library serializes runtime state. Swift remains responsible
/// for configuring its `CAMetalLayer` and acquiring each drawable.
pub unsafe extern "C" fn nux_screen_session_attach_apple_surface(
    session: *const NuxScreenSession,
    descriptor: *const NuxAppleSurfaceDescriptor,
    out_surface: *mut *mut NuxAppleSurface,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || unsafe { poison_session_handle(session) },
        || {
            reset_out_handle(out_surface);
            reset_out_handle(out_result);
            if session.is_null() || descriptor.is_null() || out_surface.is_null() {
                return NuxStatus::NullArgument;
            }
            let session = unsafe { &*session.cast::<ScreenSessionHandle>() };
            let struct_size = unsafe { read_struct_size(descriptor) };
            if struct_size != size_u32::<NuxAppleSurfaceDescriptor>() {
                return write_failure(
                    out_result,
                    NuxStatus::InvalidArgument,
                    "Apple surface descriptor has the wrong exact size",
                );
            }
            let descriptor = unsafe { *descriptor };
            let session_id = session.token.id;
            let pixel_width = descriptor.pixel_width;
            let pixel_height = descriptor.pixel_height;
            let surface_id = match session.token.worker.call(Some(session_id), move |state| {
                state.attach_surface(session_id, pixel_width, pixel_height)
            }) {
                Ok(Ok(surface_id)) => surface_id,
                Ok(Err(failure)) => return write_runtime_failure(out_result, failure),
                Err(error) => return write_worker_call_failure(out_result, error),
            };
            let surface = Box::new(AppleSurfaceHandle {
                token: Arc::new(SurfaceToken {
                    session: Arc::clone(&session.token),
                    id: surface_id,
                }),
            });
            unsafe {
                *out_surface = Box::into_raw(surface).cast();
            }
            let disposition = if pixel_width == 0 || pixel_height == 0 {
                NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE
            } else {
                NUX_SURFACE_DISPOSITION_RECREATED
            };
            write_success(out_result, disposition, false)
        },
    )
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Copies the renderer's Metal device for main-actor `CAMetalLayer` setup.
///
/// On success `out_metal_device` receives an Objective-C object pointer with
/// +1 ownership. The caller must transfer that ownership to ARC or release it.
///
/// # Safety
///
/// `surface` must be live and output pointers must be null or writable. Calls
/// may originate on arbitrary threads; this library serializes runtime state.
pub unsafe extern "C" fn nux_apple_surface_copy_metal_device(
    surface: *const NuxAppleSurface,
    out_metal_device: *mut *mut c_void,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || unsafe { poison_surface_handle(surface) },
        || {
            reset_out_handle(out_metal_device);
            reset_out_handle(out_result);
            if surface.is_null() || out_metal_device.is_null() {
                return NuxStatus::NullArgument;
            }
            let surface = unsafe { &*surface.cast::<AppleSurfaceHandle>() };
            let session_id = surface.token.session.id;
            let surface_id = surface.token.id;
            let device_identity =
                match surface
                    .token
                    .session
                    .worker
                    .call(Some(session_id), move |state| {
                        let (factory, attachment) =
                            state.session_surface_mut(session_id, surface_id)?;
                        attachment
                            .surface
                            .copy_metal_device(factory)
                            .map(|device| device.expose_provenance())
                            .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))
                    }) {
                    Ok(Ok(device_identity)) => device_identity,
                    Ok(Err(failure)) => return write_runtime_failure(out_result, failure),
                    Err(error) => return write_worker_call_failure(out_result, error),
                };
            let status = write_success(out_result, NuxSurfaceDisposition::None, false);
            unsafe {
                *out_metal_device = ptr::with_exposed_provenance_mut(device_identity);
            }
            status
        },
    )
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Resizes or zero-size-suspends one attached Apple surface.
///
/// # Safety
///
/// `surface` must be live and `out_result` must be null or writable. Calls may
/// originate on arbitrary threads; this library serializes runtime state.
pub unsafe extern "C" fn nux_apple_surface_resize(
    surface: *const NuxAppleSurface,
    pixel_width: u32,
    pixel_height: u32,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || unsafe { poison_surface_handle(surface) },
        || {
            reset_out_handle(out_result);
            if surface.is_null() {
                return NuxStatus::NullArgument;
            }
            let surface = unsafe { &*surface.cast::<AppleSurfaceHandle>() };
            let session_id = surface.token.session.id;
            let surface_id = surface.token.id;
            match surface
                .token
                .session
                .worker
                .call(Some(session_id), move |state| {
                    let (factory, attachment) =
                        state.session_surface_mut(session_id, surface_id)?;
                    attachment
                        .surface
                        .resize(factory, pixel_width, pixel_height)
                        .map_err(|error| RuntimeFailure::surface(format!("{error:#}")))
                }) {
                Ok(Ok(disposition)) => {
                    write_success(out_result, surface_disposition(disposition), false)
                }
                Ok(Err(failure)) => write_runtime_failure(out_result, failure),
                Err(error) => write_worker_call_failure(out_result, error),
            }
        },
    )
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Detaches presentation state while preserving logical session state.
///
/// # Safety
///
/// `surface` must be live and `out_result` must be null or writable. Calls may
/// originate on arbitrary threads; this library serializes runtime state.
pub unsafe extern "C" fn nux_apple_surface_detach(
    surface: *const NuxAppleSurface,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || unsafe { poison_surface_handle(surface) },
        || {
            reset_out_handle(out_result);
            if surface.is_null() {
                return NuxStatus::NullArgument;
            }
            let surface = unsafe { &*surface.cast::<AppleSurfaceHandle>() };
            let session_id = surface.token.session.id;
            let surface_id = surface.token.id;
            match surface
                .token
                .session
                .worker
                .call(Some(session_id), move |state| {
                    let (_, attachment) = state.session_surface_mut(session_id, surface_id)?;
                    attachment.surface.detach();
                    Ok::<(), RuntimeFailure>(())
                }) {
                Ok(Ok(())) => write_success(out_result, NuxSurfaceDisposition::None, false),
                Ok(Err(failure)) => write_runtime_failure(out_result, failure),
                Err(error) => write_worker_call_failure(out_result, error),
            }
        },
    )
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Reattaches logical presentation state after a detach. If the session's GPU
/// domain reported device loss, this call transactionally replaces the
/// session's renderer and presentation resources, refreshing the shared base
/// device when needed while preserving logical screen state and factory address.
///
/// # Safety
///
/// Handles, descriptor, and output storage must be valid. Calls may originate
/// on arbitrary threads; this library serializes runtime state.
pub unsafe extern "C" fn nux_apple_surface_reattach(
    surface: *const NuxAppleSurface,
    descriptor: *const NuxAppleSurfaceDescriptor,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || unsafe { poison_surface_handle(surface) },
        || {
            reset_out_handle(out_result);
            if surface.is_null() || descriptor.is_null() {
                return NuxStatus::NullArgument;
            }
            let surface = unsafe { &*surface.cast::<AppleSurfaceHandle>() };
            let struct_size = unsafe { read_struct_size(descriptor) };
            if struct_size != size_u32::<NuxAppleSurfaceDescriptor>() {
                return write_failure(
                    out_result,
                    NuxStatus::InvalidArgument,
                    "Apple surface descriptor has the wrong exact size",
                );
            }
            let descriptor = unsafe { *descriptor };
            let session_id = surface.token.session.id;
            let surface_id = surface.token.id;
            let pixel_width = descriptor.pixel_width;
            let pixel_height = descriptor.pixel_height;
            match surface
                .token
                .session
                .worker
                .call(Some(session_id), move |state| {
                    state.reattach_surface(session_id, surface_id, pixel_width, pixel_height)
                }) {
                Ok(Ok(disposition)) => {
                    write_success(out_result, surface_disposition(disposition), false)
                }
                Ok(Err(failure)) => write_runtime_failure(out_result, failure),
                Err(error) => write_worker_call_failure(out_result, error),
            }
        },
    )
}

#[unsafe(no_mangle)]
/// Releases one Apple-surface handle. Null is a no-op.
///
/// # Safety
///
/// A non-null pointer must be an owned handle returned by this library and not
/// previously released. Release must not race a call using the same handle.
pub unsafe extern "C" fn nux_apple_surface_free(surface: *mut NuxAppleSurface) {
    ffi_guard((), || {
        if !surface.is_null() {
            unsafe {
                #[cfg(feature = "apple-product")]
                drop(Box::from_raw(surface.cast::<AppleSurfaceHandle>()));
            }
        }
    })
}

#[cfg(feature = "apple-product")]
#[unsafe(no_mangle)]
/// Advances a logical session and optionally renders its attached surface.
///
/// # Safety
///
/// `session` and `operation` must be live, valid pointers; `out_result` must
/// be null or writable. When rendering, `operation.apple_drawable` may be null
/// to report a bounded no-drawable outcome; otherwise it must be a live
/// `id<CAMetalDrawable>` retained until this synchronous call returns. A
/// drawable must not be supplied when rendering is disabled. Calls may
/// originate on arbitrary threads; this library serializes runtime state.
pub unsafe extern "C" fn nux_screen_session_advance(
    session: *const NuxScreenSession,
    operation: *const NuxFrameOperation,
    out_result: *mut *mut NuxOperationResult,
) -> NuxStatus {
    ffi_guard_with_result(
        out_result,
        || unsafe { poison_session_handle(session) },
        || {
            reset_out_handle(out_result);
            if operation.is_null() {
                return NuxStatus::NullArgument;
            }
            let struct_size = unsafe { read_struct_size(operation) };
            if struct_size != size_u32::<NuxFrameOperation>() {
                return write_failure(
                    out_result,
                    NuxStatus::InvalidArgument,
                    "frame operation is invalid",
                );
            }
            let operation = unsafe { *operation };
            let completion = match PendingFrameCompletion::from_operation(&operation) {
                Ok(completion) => completion,
                Err(diagnostic) => {
                    return write_failure(out_result, NuxStatus::InvalidArgument, diagnostic);
                }
            };
            if session.is_null() {
                return NuxStatus::NullArgument;
            }
            let session = unsafe { &*session.cast::<ScreenSessionHandle>() };
            if !operation.elapsed_seconds.is_finite() || operation.elapsed_seconds < 0.0 {
                return write_failure(
                    out_result,
                    NuxStatus::InvalidArgument,
                    "frame operation is invalid",
                );
            }
            if !operation.render && !operation.apple_drawable.is_null() {
                return write_failure(
                    out_result,
                    NuxStatus::InvalidArgument,
                    "a frame operation cannot supply an Apple drawable when rendering is disabled",
                );
            }
            if operation.completion_callback.is_some() && operation.apple_drawable.is_null() {
                return write_failure(
                    out_result,
                    NuxStatus::InvalidArgument,
                    "a frame completion callback requires an Apple drawable",
                );
            }
            let session_id = session.token.id;
            let elapsed_seconds = operation.elapsed_seconds;
            let render = operation.render;
            let drawable_identity = operation.apple_drawable.expose_provenance();
            match session.token.worker.call(Some(session_id), move |state| {
                state.require_live_session(session_id)?;
                let session = state.session_mut(session_id)?;
                let timestamp_seconds =
                    session.legacy_timestamp_seconds + f64::from(elapsed_seconds);
                if !timestamp_seconds.is_finite() {
                    return Err(RuntimeFailure::runtime("legacy timestamp overflowed"));
                }
                let preflight_disposition = if render {
                    session.preflight_present(drawable_identity != 0)?
                } else {
                    None
                };
                if matches!(preflight_disposition, Some(SurfaceDisposition::DeviceLost)) {
                    return Ok((NUX_SURFACE_DISPOSITION_DEVICE_LOST, false));
                }
                let mut result = session
                    .screen_session
                    .perform_with_factory(
                        nuxie::flow_session::FlowOperation::Advance(
                            nuxie::flow_session::FlowAdvance {
                                timestamp_seconds,
                                delta_seconds: elapsed_seconds,
                                render,
                            },
                        ),
                        session.factory.as_mut(),
                    )
                    .map_err(runtime_failure_from_screen_session)?;
                session.legacy_timestamp_seconds = timestamp_seconds;
                let changed = result.dirty;
                if !render {
                    return Ok((NuxSurfaceDisposition::None, changed));
                }
                if let Some(disposition) = preflight_disposition {
                    return Ok((surface_disposition(disposition), changed));
                }
                let Some((viewport_width, viewport_height)) = session
                    .attachment
                    .as_ref()
                    .map(|attachment| attachment.surface.dimensions())
                else {
                    let failure = RuntimeFailure::runtime("preflighted surface became unavailable");
                    return Err(terminalize_after_committed_advance_failure(
                        session,
                        "presentation setup",
                        failure,
                    ));
                };
                let bounds = session.screen_session.artboard_bounds();
                let presentation_transform = match centered_contain_transform(
                    bounds.x,
                    bounds.y,
                    bounds.width,
                    bounds.height,
                    viewport_width,
                    viewport_height,
                ) {
                    Ok(transform) => transform,
                    Err(failure) => {
                        return Err(terminalize_after_committed_advance_failure(
                            session,
                            "presentation transform",
                            failure,
                        ));
                    }
                };
                let mut frame = session.factory.begin_frame(0x0000_0000);
                frame.transform(presentation_transform);
                #[cfg(test)]
                {
                    session.render_attempts = session.render_attempts.saturating_add(1);
                }
                let draw_result = session.screen_session.draw_into_result(
                    session.factory.as_mut(),
                    &mut frame,
                    &mut result,
                );
                if let Err(error) = draw_result {
                    let failure = runtime_failure_from_screen_session(error);
                    return Err(terminalize_after_committed_advance_failure(
                        session, "drawing", failure,
                    ));
                }
                let drawable = ptr::with_exposed_provenance_mut::<c_void>(drawable_identity);
                let completion = completion.into_renderer_completion();
                let presentation = {
                    let Some(attachment) = session.attachment.as_mut() else {
                        let failure =
                            RuntimeFailure::runtime("preflighted surface became unavailable");
                        return Err(terminalize_after_committed_advance_failure(
                            session,
                            "presentation setup",
                            failure,
                        ));
                    };
                    unsafe {
                        attachment.surface.present(
                            &mut session.factory,
                            frame,
                            drawable,
                            completion,
                        )
                    }
                };
                let (disposition, _metrics) = match presentation {
                    Ok(presentation) => presentation,
                    Err(error) => {
                        let failure = RuntimeFailure::surface(format!("{error:#}"));
                        return Err(terminalize_after_committed_advance_failure(
                            session,
                            "presentation",
                            failure,
                        ));
                    }
                };
                Ok((surface_disposition(disposition), changed))
            }) {
                Ok(Ok((disposition, changed))) => write_success(out_result, disposition, changed),
                Ok(Err(failure)) => write_runtime_failure(out_result, failure),
                Err(error) => write_worker_call_failure(out_result, error),
            }
        },
    )
}

#[unsafe(no_mangle)]
/// Returns an operation result's status, or `NULL_ARGUMENT` for null.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_operation_result_status(
    result: *const NuxOperationResult,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if result.is_null() {
            NuxStatus::NullArgument
        } else {
            unsafe { (*result).status }
        }
    })
}

#[unsafe(no_mangle)]
/// Returns an operation result's surface disposition.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_operation_result_surface_disposition(
    result: *const NuxOperationResult,
) -> NuxSurfaceDisposition {
    ffi_guard(NuxSurfaceDisposition::Fatal, || {
        if result.is_null() {
            NuxSurfaceDisposition::Fatal
        } else {
            unsafe { (*result).surface_disposition }
        }
    })
}

#[unsafe(no_mangle)]
/// Returns whether an operation changed logical runtime state.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_operation_result_changed(result: *const NuxOperationResult) -> bool {
    ffi_guard(false, || !result.is_null() && unsafe { (*result).changed })
}

#[unsafe(no_mangle)]
/// Borrows the authenticated key ID stored by an import result.
///
/// # Safety
///
/// `result` must be live and `out_key_id` writable. The returned view expires
/// when `result` is released.
pub unsafe extern "C" fn nux_operation_result_authenticated_key_id(
    result: *const NuxOperationResult,
    out_key_id: *mut NuxByteView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_key_id.is_null() {
            return NuxStatus::NullArgument;
        }
        unsafe {
            *out_key_id = NuxByteView::default();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let key_id = unsafe { &(*result).authenticated_key_id };
        if key_id.is_empty() {
            return NuxStatus::NotFound;
        }
        unsafe {
            *out_key_id = NuxByteView {
                data: key_id.as_ptr(),
                len: u64::try_from(key_id.len()).unwrap_or(u64::MAX),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Returns the number of phase-ordered structured diagnostics in a result.
///
/// # Safety
///
/// A non-null pointer must identify a live result owned by this library.
pub unsafe extern "C" fn nux_operation_result_diagnostic_count(
    result: *const NuxOperationResult,
) -> u64 {
    ffi_guard(0, || {
        if result.is_null() {
            0
        } else {
            u64::try_from(unsafe { (*result).diagnostics.len() }).unwrap_or(u64::MAX)
        }
    })
}

#[unsafe(no_mangle)]
/// Borrows one structured diagnostic by stable result order.
///
/// # Safety
///
/// `result` must be live and `out_diagnostic` writable with `struct_size`
/// initialized to the exact published layout size. Returned views expire when
/// `result` is released.
pub unsafe extern "C" fn nux_operation_result_diagnostic_at(
    result: *const NuxOperationResult,
    index: u64,
    out_diagnostic: *mut NuxDiagnosticView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_diagnostic.is_null() {
            return NuxStatus::NullArgument;
        }
        let caller_struct_size = unsafe { read_struct_size(out_diagnostic) };
        if caller_struct_size != size_u32::<NuxDiagnosticView>() {
            return NuxStatus::InvalidArgument;
        }
        unsafe {
            *out_diagnostic = NuxDiagnosticView::default();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let Ok(index) = usize::try_from(index) else {
            return NuxStatus::NotFound;
        };
        let Some(diagnostic) = (unsafe { &(*result).diagnostics }).get(index) else {
            return NuxStatus::NotFound;
        };
        unsafe {
            *out_diagnostic = NuxDiagnosticView {
                struct_size: size_u32::<NuxDiagnosticView>(),
                severity: diagnostic.severity,
                code: NuxByteView {
                    data: diagnostic.code.as_ptr(),
                    len: u64::try_from(diagnostic.code.len()).unwrap_or(u64::MAX),
                },
                message: NuxByteView {
                    data: diagnostic.message.as_ptr(),
                    len: u64::try_from(diagnostic.message.len()).unwrap_or(u64::MAX),
                },
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Borrows the diagnostic bytes stored by an operation result.
///
/// # Safety
///
/// `result` must be null or live, and `out_diagnostic` must point to writable
/// storage. A returned byte view expires when `result` is released.
pub unsafe extern "C" fn nux_operation_result_diagnostic(
    result: *const NuxOperationResult,
    out_diagnostic: *mut NuxByteView,
) -> NuxStatus {
    ffi_guard(NuxStatus::RuntimeError, || {
        if out_diagnostic.is_null() {
            return NuxStatus::NullArgument;
        }
        unsafe {
            *out_diagnostic = NuxByteView::default();
        }
        if result.is_null() {
            return NuxStatus::NullArgument;
        }
        let diagnostic = unsafe { &(*result).diagnostic };
        unsafe {
            *out_diagnostic = NuxByteView {
                data: diagnostic.as_ptr(),
                len: u64::try_from(diagnostic.len()).unwrap_or(u64::MAX),
            };
        }
        NuxStatus::Ok
    })
}

#[unsafe(no_mangle)]
/// Releases one operation result. Null is a no-op.
///
/// # Safety
///
/// A non-null pointer must be an owned result returned by this library and
/// must not have been released before.
pub unsafe extern "C" fn nux_operation_result_free(result: *mut NuxOperationResult) {
    ffi_guard((), || {
        if !result.is_null() {
            unsafe {
                drop(Box::from_raw(result));
            }
        }
    })
}

fn size_u32<T>() -> u32 {
    u32::try_from(std::mem::size_of::<T>()).unwrap_or(u32::MAX)
}

unsafe fn read_struct_size<T>(value: *const T) -> u32 {
    // SAFETY: every versioned input begins with a u32 `struct_size`, and the
    // FFI contract requires the non-null pointer to be aligned and readable
    // for at least that prefix. The caller's declared size is validated before
    // any full-structure read occurs.
    unsafe { value.cast::<u32>().read() }
}

fn byte_vec(view: NuxByteView, maximum_length: usize) -> Result<Vec<u8>, NuxStatus> {
    let len = usize::try_from(view.len).map_err(|_| NuxStatus::InvalidArgument)?;
    if len > maximum_length || len > isize::MAX as usize {
        return Err(NuxStatus::InvalidArgument);
    }
    if view.data.is_null() && len != 0 {
        return Err(NuxStatus::NullArgument);
    }
    if len == 0 {
        return Ok(Vec::new());
    }
    // SAFETY: the caller promises the view remains valid for the duration of
    // the importing call. Copying here prevents a caller-owned lifetime from
    // leaking into the retained runtime context.
    Ok(unsafe { slice::from_raw_parts(view.data, len) }.to_vec())
}

#[cfg(feature = "apple-product")]
fn required_utf8_string(view: NuxByteView, maximum_length: usize) -> Result<String, NuxStatus> {
    let bytes = byte_vec(view, maximum_length)?;
    if bytes.is_empty() {
        return Err(NuxStatus::InvalidArgument);
    }
    String::from_utf8(bytes).map_err(|_| NuxStatus::InvalidArgument)
}

#[cfg(feature = "apple-product")]
unsafe fn required_c_string(
    value: *const c_char,
    maximum_length: usize,
) -> Result<String, NuxStatus> {
    if value.is_null() {
        return Err(NuxStatus::NullArgument);
    }
    // SAFETY: the FFI contract requires a readable NUL-terminated string.
    let value = unsafe { CStr::from_ptr(value) };
    let bytes = value.to_bytes();
    if bytes.is_empty() || bytes.len() > maximum_length {
        return Err(NuxStatus::InvalidArgument);
    }
    value
        .to_str()
        .map(str::to_owned)
        .map_err(|_| NuxStatus::InvalidArgument)
}

#[cfg(feature = "apple-product")]
struct ImportRequestCopyError {
    status: NuxStatus,
    code: &'static str,
    message: &'static str,
}

#[cfg(feature = "apple-product")]
impl ImportRequestCopyError {
    const fn invalid(status: NuxStatus) -> Self {
        Self {
            status,
            code: "package.request.invalid",
            message: "experience import request contains an invalid view or value",
        }
    }

    const fn oversize() -> Self {
        Self {
            status: NuxStatus::InvalidArgument,
            code: "package.oversize",
            message: "experience package exceeds the published size limit",
        }
    }
}

#[cfg(feature = "apple-product")]
unsafe fn copy_experience_import_input(
    request: *const NuxExperienceImportRequest,
) -> Result<ExperiencePackageImportInput, ImportRequestCopyError> {
    let struct_size = unsafe { read_struct_size(request) };
    if struct_size != size_u32::<NuxExperienceImportRequest>() {
        return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
    }

    let request = unsafe { request.read() };
    if request.package_bytes.len > nux_container::NUX_MAX_PACKAGE_BYTES {
        return Err(ImportRequestCopyError::oversize());
    }
    let package_bytes = byte_vec(
        request.package_bytes,
        usize::try_from(nux_container::NUX_MAX_PACKAGE_BYTES).unwrap_or(usize::MAX),
    )
    .map_err(ImportRequestCopyError::invalid)?;
    let expected_experience_id =
        unsafe { required_c_string(request.expected_experience_id, MAX_SELECTOR_BYTE_LENGTH) }
            .map_err(ImportRequestCopyError::invalid)?;
    let expected_build_id =
        unsafe { required_c_string(request.expected_build_id, MAX_SELECTOR_BYTE_LENGTH) }
            .map_err(ImportRequestCopyError::invalid)?;

    let candidate_key_count = usize::try_from(request.candidate_key_count)
        .map_err(|_| ImportRequestCopyError::invalid(NuxStatus::InvalidArgument))?;
    if candidate_key_count > MAX_CANDIDATE_KEY_COUNT
        || (candidate_key_count != 0 && request.candidate_keys.is_null())
    {
        return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
    }
    let candidate_key_array_size = candidate_key_count
        .checked_mul(std::mem::size_of::<NuxExperienceAuthorizationKey>())
        .ok_or_else(|| ImportRequestCopyError::invalid(NuxStatus::InvalidArgument))?;
    if candidate_key_array_size > isize::MAX as usize {
        return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
    }
    let candidate_key_views = if candidate_key_count == 0 {
        &[][..]
    } else {
        // SAFETY: the caller promises an array of readable elements for this
        // synchronous call; nested views are copied before returning.
        unsafe { slice::from_raw_parts(request.candidate_keys, candidate_key_count) }
    };
    let mut candidate_keys = Vec::with_capacity(candidate_key_count);
    for candidate_key in candidate_key_views {
        if candidate_key.struct_size != size_u32::<NuxExperienceAuthorizationKey>() {
            return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
        }
        let key_id =
            required_utf8_string(candidate_key.key_id, MAX_AUTHORIZATION_KEY_ID_BYTE_LENGTH)
                .map_err(ImportRequestCopyError::invalid)?;
        let public_key = byte_vec(
            candidate_key.ed25519_public_key,
            ED25519_PUBLIC_KEY_BYTE_LENGTH,
        )
        .map_err(ImportRequestCopyError::invalid)?;
        let public_key: [u8; ED25519_PUBLIC_KEY_BYTE_LENGTH] = public_key
            .try_into()
            .map_err(|_| ImportRequestCopyError::invalid(NuxStatus::InvalidArgument))?;
        candidate_keys.push(CandidateExperienceSigningKey { key_id, public_key });
    }

    let external_asset_count = usize::try_from(request.external_asset_count)
        .map_err(|_| ImportRequestCopyError::invalid(NuxStatus::InvalidArgument))?;
    if external_asset_count > MAX_EXTERNAL_ASSET_COUNT
        || (external_asset_count != 0 && request.external_assets.is_null())
    {
        return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
    }
    let external_asset_array_size = external_asset_count
        .checked_mul(std::mem::size_of::<NuxExperienceExternalAsset>())
        .ok_or_else(|| ImportRequestCopyError::invalid(NuxStatus::InvalidArgument))?;
    if external_asset_array_size > isize::MAX as usize {
        return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
    }
    let external_asset_views = if external_asset_count == 0 {
        &[][..]
    } else {
        // SAFETY: the caller promises an array of `external_asset_count`
        // readable elements for this synchronous call. Every nested view is
        // copied below before the runtime worker can retain the import.
        unsafe { slice::from_raw_parts(request.external_assets, external_asset_count) }
    };
    let mut external_assets = Vec::with_capacity(external_asset_count);
    let mut cumulative_asset_bytes = 0usize;
    for asset in external_asset_views {
        // Array elements have no separate stride parameter. Accepting a larger
        // element declaration would make the second element start ambiguous,
        // so the runtime requires the exact published element size.
        if asset.struct_size != size_u32::<NuxExperienceExternalAsset>() {
            return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
        }
        let kind = match asset.kind {
            NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_IMAGE => ExternalAssetKind::Image,
            NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_FONT => ExternalAssetKind::Font,
            _ => {
                return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
            }
        };
        let unique_name = required_utf8_string(asset.unique_name, MAX_SELECTOR_BYTE_LENGTH)
            .map_err(ImportRequestCopyError::invalid)?;
        let source_key = required_utf8_string(asset.source_key, MAX_ASSET_SOURCE_KEY_BYTE_LENGTH)
            .map_err(ImportRequestCopyError::invalid)?;
        let expected_sha256 = required_utf8_string(asset.expected_sha256, MAX_SELECTOR_BYTE_LENGTH)
            .map_err(ImportRequestCopyError::invalid)?;
        let input = if asset.provided {
            if asset.bytes.len > nux_container::NUX_MAX_EXTERNAL_ASSET_BYTES {
                return Err(ImportRequestCopyError::oversize());
            }
            let bytes = byte_vec(
                asset.bytes,
                usize::try_from(nux_container::NUX_MAX_EXTERNAL_ASSET_BYTES).unwrap_or(usize::MAX),
            )
            .map_err(ImportRequestCopyError::invalid)?;
            cumulative_asset_bytes = cumulative_asset_bytes
                .checked_add(bytes.len())
                .ok_or_else(|| ImportRequestCopyError::invalid(NuxStatus::InvalidArgument))?;
            if cumulative_asset_bytes > MAX_EXTERNAL_ASSET_TOTAL_BYTE_LENGTH {
                return Err(ImportRequestCopyError::oversize());
            }
            ExternalAssetInput::Supplied {
                kind,
                asset_id: asset.asset_id,
                unique_name,
                source_key,
                expected_sha256,
                required: asset.required,
                bytes,
            }
        } else {
            if !asset.bytes.data.is_null() || asset.bytes.len != 0 {
                return Err(ImportRequestCopyError::invalid(NuxStatus::InvalidArgument));
            }
            ExternalAssetInput::Omitted {
                kind,
                asset_id: asset.asset_id,
                unique_name,
                source_key,
                expected_sha256,
                required: asset.required,
            }
        };
        external_assets.push(input);
    }

    Ok(ExperiencePackageImportInput {
        expected_experience_id,
        expected_build_id,
        package_bytes,
        candidate_keys,
        external_assets,
    })
}

fn optional_utf8_string(view: NuxByteView) -> Result<Option<String>, NuxStatus> {
    if view.data.is_null() && view.len == 0 {
        return Ok(None);
    }
    let bytes = byte_vec(view, MAX_SELECTOR_BYTE_LENGTH)?;
    String::from_utf8(bytes)
        .map(Some)
        .map_err(|_| NuxStatus::InvalidArgument)
}

#[cfg(feature = "apple-product")]
unsafe fn poison_session_handle(session: *const NuxScreenSession) {
    if session.is_null() {
        return;
    }
    let handle = unsafe { &*session.cast::<ScreenSessionHandle>() };
    handle.token.worker.poison_session(handle.token.id);
}

#[cfg(feature = "apple-product")]
unsafe fn poison_surface_handle(surface: *const NuxAppleSurface) {
    if surface.is_null() {
        return;
    }
    let handle = unsafe { &*surface.cast::<AppleSurfaceHandle>() };
    handle
        .token
        .session
        .worker
        .poison_session(handle.token.session.id);
}

fn reset_out_handle<T>(out: *mut *mut T) {
    if !out.is_null() {
        unsafe {
            *out = ptr::null_mut();
        }
    }
}

fn write_success(
    out_result: *mut *mut NuxOperationResult,
    surface_disposition: NuxSurfaceDisposition,
    changed: bool,
) -> NuxStatus {
    replace_result(
        out_result,
        NuxOperationResult::success(surface_disposition, changed),
    );
    NuxStatus::Ok
}

fn write_failure(
    out_result: *mut *mut NuxOperationResult,
    status: NuxStatus,
    diagnostic: impl Into<Vec<u8>>,
) -> NuxStatus {
    replace_result(out_result, NuxOperationResult::failure(status, diagnostic));
    status
}

fn write_failure_with_code(
    out_result: *mut *mut NuxOperationResult,
    status: NuxStatus,
    code: impl Into<Vec<u8>>,
    diagnostic: impl Into<Vec<u8>>,
) -> NuxStatus {
    replace_result(
        out_result,
        NuxOperationResult::failure_with_code(status, code, diagnostic),
    );
    status
}

fn write_import_failure(
    out_result: *mut *mut NuxOperationResult,
    status: NuxStatus,
    code: impl Into<Vec<u8>>,
    message: impl Into<Vec<u8>>,
) -> NuxStatus {
    replace_result(
        out_result,
        NuxOperationResult::import_failure(status, code, message),
    );
    status
}

#[cfg(feature = "apple-product")]
fn write_runtime_failure(
    out_result: *mut *mut NuxOperationResult,
    failure: RuntimeFailure,
) -> NuxStatus {
    write_failure_with_code(
        out_result,
        failure.status,
        failure.diagnostic_code,
        failure.diagnostic,
    )
}

#[cfg(feature = "apple-product")]
fn write_worker_call_failure(
    out_result: *mut *mut NuxOperationResult,
    error: WorkerCallError,
) -> NuxStatus {
    let diagnostic = match error {
        WorkerCallError::Panicked => PANIC_DIAGNOSTIC,
        WorkerCallError::Unavailable => "runtime worker is unavailable",
    };
    write_failure(out_result, NuxStatus::RuntimeError, diagnostic)
}

fn replace_result(out_result: *mut *mut NuxOperationResult, result: NuxOperationResult) {
    if out_result.is_null() {
        return;
    }
    let replacement = Box::into_raw(Box::new(result));
    let previous = unsafe { std::mem::replace(&mut *out_result, replacement) };
    if !previous.is_null() {
        unsafe {
            drop(Box::from_raw(previous));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2::rc::{Retained, autoreleasepool};
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2::runtime::ProtocolObject;
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2_core_foundation::CGSize;
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2_metal::{MTLDevice, MTLPixelFormat};
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use objc2_quartz_core::CAMetalLayer;
    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    use std::sync::atomic::{AtomicBool, Ordering};

    unsafe fn operation_result_message(result: *const NuxOperationResult) -> String {
        if result.is_null() {
            return "operation returned no result".to_owned();
        }
        String::from_utf8_lossy(unsafe { &(*result).diagnostic }).into_owned()
    }

    #[cfg(feature = "apple-product")]
    unsafe fn operation_result_code(result: *const NuxOperationResult) -> String {
        let mut diagnostic = NuxDiagnosticView::default();
        assert_eq!(
            unsafe { nux_operation_result_diagnostic_at(result, 0, &mut diagnostic) },
            NuxStatus::Ok
        );
        let code =
            unsafe { slice::from_raw_parts(diagnostic.code.data, diagnostic.code.len as usize) };
        String::from_utf8(code.to_vec()).expect("diagnostic code must be UTF-8")
    }

    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    unsafe extern "C" fn mark_frame_completed(context: *mut c_void) {
        if let Some(completed) = std::ptr::NonNull::new(context.cast::<AtomicBool>()) {
            unsafe {
                completed.as_ref().store(true, Ordering::Release);
            }
        }
    }

    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    fn wait_for_frame_completion(completed: &AtomicBool) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while !completed.load(Ordering::Acquire) {
            assert!(
                std::time::Instant::now() < deadline,
                "Metal frame completion callback timed out"
            );
            std::thread::yield_now();
        }
    }

    #[cfg(feature = "apple-product")]
    fn product_fixture_bytes() -> Vec<u8> {
        let fixture = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .join("fixtures/animation/smi_test.riv");
        std::fs::read(fixture).expect("product fixture must be readable")
    }

    #[cfg(feature = "apple-product")]
    struct SignedImportRequest {
        request: NuxExperienceImportRequest,
        _package: Vec<u8>,
        _experience_id: std::ffi::CString,
        _build_id: std::ffi::CString,
        _key_id: Vec<u8>,
        _public_key: Box<[u8; 32]>,
        _candidate_key: Box<NuxExperienceAuthorizationKey>,
    }

    #[cfg(feature = "apple-product")]
    fn signed_import_request(scene: &[u8]) -> SignedImportRequest {
        use nux_container::test_support::{TEST_ONLY_DEV_KEY_ID, TEST_ONLY_DEV_KEYPAIR};
        use nux_container::{
            Assets, Entry, Identity, JourneyMember, LuauProducer, NuxPackageManifestV1,
            NuxPackageModel, Producer, SceneFormat, SceneMember, Screen, SignatureSource,
            write_package,
        };

        let manifest = NuxPackageManifestV1 {
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
                width: 100.0,
                height: 100.0,
            }],
            text_inputs: Vec::new(),
            assets: Assets::default(),
            members: Vec::new(),
        };
        let package = write_package(&NuxPackageModel {
            manifest,
            scene,
            journey: br#"{"schemaVersion":1}"#,
            embedded_assets: Vec::new(),
            signature: SignatureSource::Signer(&*TEST_ONLY_DEV_KEYPAIR),
        })
        .expect("test package encodes");
        let experience_id =
            std::ffi::CString::new("test-experience").expect("valid experience identity");
        let build_id = std::ffi::CString::new("test-build").expect("valid build identity");
        let key_id = TEST_ONLY_DEV_KEY_ID.as_bytes().to_vec();
        let public_key = Box::new(TEST_ONLY_DEV_KEYPAIR.public_key());
        let candidate_key = Box::new(NuxExperienceAuthorizationKey {
            struct_size: size_u32::<NuxExperienceAuthorizationKey>(),
            key_id: NuxByteView {
                data: key_id.as_ptr(),
                len: key_id.len() as u64,
            },
            ed25519_public_key: NuxByteView {
                data: public_key.as_ptr(),
                len: public_key.len() as u64,
            },
        });
        let request = NuxExperienceImportRequest {
            struct_size: size_u32::<NuxExperienceImportRequest>(),
            package_bytes: NuxByteView {
                data: package.as_ptr(),
                len: package.len() as u64,
            },
            expected_experience_id: experience_id.as_ptr(),
            expected_build_id: build_id.as_ptr(),
            candidate_keys: ptr::from_ref(candidate_key.as_ref()),
            candidate_key_count: 1,
            external_assets: ptr::null(),
            external_asset_count: 0,
        };
        SignedImportRequest {
            request,
            _package: package,
            _experience_id: experience_id,
            _build_id: build_id,
            _key_id: key_id,
            _public_key: public_key,
            _candidate_key: candidate_key,
        }
    }
    #[cfg(feature = "apple-product")]
    fn product_fixture_worker() -> Arc<RuntimeWorker> {
        match RuntimeWorker::spawn(product_fixture_bytes()) {
            Ok(worker) => worker,
            Err(_) => panic!("product fixture must create a runtime worker"),
        }
    }

    #[test]
    fn exact_runtime_identity_returns_an_opaque_binding() {
        let mut binding = ptr::null();

        assert_eq!(
            unsafe {
                nux_runtime_bind(
                    RUNTIME_VERSION.as_ptr(),
                    RUNTIME_VERSION.len() as u64,
                    SOURCE_REVISION.as_ptr(),
                    SOURCE_REVISION.len() as u64,
                    &mut binding,
                )
            },
            NuxStatus::Ok
        );
        assert!(!binding.is_null());
    }

    #[test]
    fn different_runtime_version_returns_identity_mismatch_and_no_binding() {
        let different_version = b"0.0.0";
        let mut binding = runtime_binding();

        assert_eq!(
            unsafe {
                nux_runtime_bind(
                    different_version.as_ptr(),
                    different_version.len() as u64,
                    SOURCE_REVISION.as_ptr(),
                    SOURCE_REVISION.len() as u64,
                    &mut binding,
                )
            },
            NuxStatus::RuntimeIdentityMismatch
        );
        assert!(binding.is_null());
    }

    #[test]
    fn different_source_revision_returns_identity_mismatch_and_no_binding() {
        let different_revision = b"0000000000000000000000000000000000000000";
        let mut binding = runtime_binding();

        assert_eq!(
            unsafe {
                nux_runtime_bind(
                    RUNTIME_VERSION.as_ptr(),
                    RUNTIME_VERSION.len() as u64,
                    different_revision.as_ptr(),
                    different_revision.len() as u64,
                    &mut binding,
                )
            },
            NuxStatus::RuntimeIdentityMismatch
        );
        assert!(binding.is_null());
    }

    #[test]
    fn empty_runtime_identity_parts_are_invalid_and_return_no_binding() {
        for (version, revision) in [
            (b"".as_slice(), SOURCE_REVISION.as_bytes()),
            (RUNTIME_VERSION.as_bytes(), b"".as_slice()),
        ] {
            let mut binding = runtime_binding();
            assert_eq!(
                unsafe {
                    nux_runtime_bind(
                        version.as_ptr(),
                        version.len() as u64,
                        revision.as_ptr(),
                        revision.len() as u64,
                        &mut binding,
                    )
                },
                NuxStatus::InvalidArgument
            );
            assert!(binding.is_null());
        }
    }

    #[test]
    fn invalid_runtime_identity_pointer_and_length_pairs_fail_before_reading() {
        for (version, version_len) in [
            (ptr::null(), 1),
            (
                ptr::dangling(),
                MAX_RUNTIME_IDENTITY_PART_BYTE_LENGTH as u64 + 1,
            ),
        ] {
            let mut binding = runtime_binding();
            assert_eq!(
                unsafe {
                    nux_runtime_bind(
                        version,
                        version_len,
                        SOURCE_REVISION.as_ptr(),
                        SOURCE_REVISION.len() as u64,
                        &mut binding,
                    )
                },
                NuxStatus::InvalidArgument
            );
            assert!(binding.is_null());
        }
    }

    #[test]
    fn runtime_bind_requires_writable_output_storage() {
        assert_eq!(
            unsafe {
                nux_runtime_bind(
                    RUNTIME_VERSION.as_ptr(),
                    RUNTIME_VERSION.len() as u64,
                    SOURCE_REVISION.as_ptr(),
                    SOURCE_REVISION.len() as u64,
                    ptr::null_mut(),
                )
            },
            NuxStatus::NullArgument
        );
    }

    #[test]
    fn malformed_runtime_identity_view_is_invalid_and_returns_no_binding() {
        let malformed_version = [0xff];
        let mut binding = runtime_binding();

        assert_eq!(
            unsafe {
                nux_runtime_bind(
                    malformed_version.as_ptr(),
                    malformed_version.len() as u64,
                    SOURCE_REVISION.as_ptr(),
                    SOURCE_REVISION.len() as u64,
                    &mut binding,
                )
            },
            NuxStatus::InvalidArgument
        );
        assert!(binding.is_null());
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn context_creation_rejects_a_foreign_binding_before_reading_the_request() {
        let foreign_binding = ptr::dangling::<NuxRuntimeBinding>();
        let unreadable_request = ptr::dangling::<NuxExperienceImportRequest>();
        let mut context = ptr::null_mut();
        let mut result = ptr::null_mut();

        assert_eq!(
            unsafe {
                nux_experience_context_create_bound(
                    foreign_binding,
                    unreadable_request,
                    &mut context,
                    &mut result,
                )
            },
            NuxStatus::RuntimeIdentityMismatch
        );
        assert!(context.is_null());
        assert_eq!(
            unsafe { nux_operation_result_status(result) },
            NuxStatus::RuntimeIdentityMismatch
        );
        unsafe { nux_operation_result_free(result) };
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn context_creation_requires_a_non_null_runtime_binding() {
        let unreadable_request = ptr::dangling::<NuxExperienceImportRequest>();
        let mut context = ptr::null_mut();
        let mut result = ptr::null_mut();

        assert_eq!(
            unsafe {
                nux_experience_context_create_bound(
                    ptr::null(),
                    unreadable_request,
                    &mut context,
                    &mut result,
                )
            },
            NuxStatus::NullArgument
        );
        assert!(context.is_null());
        assert!(result.is_null());
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn package_import_error_code_crosses_the_public_result_accessor() {
        let scene = product_fixture_bytes();
        let mut request = signed_import_request(&scene);
        request.request.candidate_keys = ptr::null();
        request.request.candidate_key_count = 0;
        let mut context = ptr::null_mut();
        let mut result = ptr::null_mut();

        assert_eq!(
            unsafe {
                nux_experience_context_create_bound(
                    runtime_binding(),
                    &request.request,
                    &mut context,
                    &mut result,
                )
            },
            NuxStatus::ImportError
        );
        assert!(context.is_null());
        assert_eq!(
            unsafe { operation_result_code(result) },
            "package.signature.unknown_key"
        );
        unsafe { nux_operation_result_free(result) };
    }

    #[test]
    fn provenance_is_process_static_json_with_required_identity_fields() {
        let mut view = NuxByteView::default();
        assert_eq!(
            unsafe { nux_runtime_build_provenance(&mut view) },
            NuxStatus::Ok
        );
        let bytes = unsafe { slice::from_raw_parts(view.data, view.len as usize) };
        let json = std::str::from_utf8(bytes).expect("build provenance must be UTF-8");
        for field in [
            "\"schemaVersion\":2",
            "\"runtimeVersion\"",
            "\"sourceRevision\"",
            "\"runtimeIdentity\"",
            "\"contractFingerprint\"",
            "\"target\"",
            "\"profile\"",
            "\"rustc\"",
            "\"wgpuVersion\":\"30.0.0\"",
        ] {
            assert!(json.contains(field), "missing {field} in {json}");
        }
        for removed_field in [
            "\"abiMajor\"",
            "\"abiMinor\"",
            "\"runtimeAbiMajor\"",
            "\"runtimeAbiMinor\"",
            "\"flowSessionAbiMinor\"",
        ] {
            assert!(
                !json.contains(removed_field),
                "client-facing ABI metadata leaked through {removed_field} in {json}"
            );
        }
        let expected_identity = format!("{RUNTIME_VERSION}@{SOURCE_REVISION}");
        assert!(
            json.contains(&format!("\"runtimeIdentity\":\"{expected_identity}\"")),
            "missing exact runtime identity in {json}"
        );
        let luaur_field = if cfg!(feature = "apple-product") {
            "\"luaurVersion\":\"0.1.8\""
        } else {
            "\"luaurVersion\":null"
        };
        assert!(
            json.contains(luaur_field),
            "missing {luaur_field} in {json}"
        );
        if let Some(profile) = option_env!("NUX_RUNTIME_BUILD_PROFILE") {
            let expected = format!("\"profile\":\"{profile}\"");
            assert!(json.contains(&expected), "missing {expected} in {json}");
        }
    }

    #[test]
    fn result_getters_are_null_safe_and_diagnostics_borrow_the_result() {
        let mut diagnostic = NuxByteView {
            data: std::ptr::NonNull::<u8>::dangling().as_ptr(),
            len: 99,
        };
        assert_eq!(
            unsafe { nux_operation_result_diagnostic(ptr::null(), &mut diagnostic) },
            NuxStatus::NullArgument
        );
        assert!(diagnostic.data.is_null());
        assert_eq!(diagnostic.len, 0);

        let result = Box::into_raw(Box::new(NuxOperationResult::failure(
            NuxStatus::InvalidArgument,
            b"bad request".to_vec(),
        )));
        assert_eq!(
            unsafe { nux_operation_result_diagnostic(result, &mut diagnostic) },
            NuxStatus::Ok
        );
        let bytes = unsafe { slice::from_raw_parts(diagnostic.data, diagnostic.len as usize) };
        assert_eq!(bytes, b"bad request");
        assert_eq!(unsafe { nux_operation_result_diagnostic_count(result) }, 1);
        let mut undersized = NuxDiagnosticView {
            struct_size: size_u32::<u32>(),
            ..NuxDiagnosticView::default()
        };
        assert_eq!(
            unsafe { nux_operation_result_diagnostic_at(result, 0, &mut undersized) },
            NuxStatus::InvalidArgument
        );
        let mut structured = NuxDiagnosticView::default();
        assert_eq!(
            unsafe { nux_operation_result_diagnostic_at(result, 0, &mut structured) },
            NuxStatus::Ok
        );
        assert_eq!(structured.severity, NUX_DIAGNOSTIC_SEVERITY_FATAL);
        let code =
            unsafe { slice::from_raw_parts(structured.code.data, structured.code.len as usize) };
        assert_eq!(code, b"nux_runtime.invalid_argument");
        assert_eq!(
            unsafe { nux_operation_result_diagnostic_at(result, 1, &mut structured) },
            NuxStatus::NotFound
        );
        assert!(structured.code.data.is_null());
        unsafe { nux_operation_result_free(result) };
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn screen_session_failure_codes_cross_the_structured_diagnostic_seam() {
        let cases = [
            (
                FlowSessionErrorKind::ScriptResourceExceeded,
                SCRIPT_RESOURCE_DIAGNOSTIC_CODE,
            ),
            (
                FlowSessionErrorKind::ResultLimitExceeded,
                RESULT_LIMIT_DIAGNOSTIC_CODE,
            ),
            (
                FlowSessionErrorKind::Runtime,
                diagnostic_code_for_status(NuxStatus::RuntimeError),
            ),
        ];

        for (kind, expected_code) in cases {
            let mut result = ptr::null_mut();
            let failure = RuntimeFailure::screen_session(kind, "flow operation failed");
            assert_eq!(
                write_runtime_failure(&mut result, failure),
                NuxStatus::RuntimeError
            );
            assert_eq!(
                unsafe { nux_operation_result_status(result) },
                NuxStatus::RuntimeError
            );
            assert_eq!(unsafe { nux_operation_result_diagnostic_count(result) }, 1);

            let mut diagnostic = NuxDiagnosticView::default();
            assert_eq!(
                unsafe { nux_operation_result_diagnostic_at(result, 0, &mut diagnostic) },
                NuxStatus::Ok
            );
            let code = unsafe {
                slice::from_raw_parts(diagnostic.code.data, diagnostic.code.len as usize)
            };
            assert_eq!(code, expected_code);
            unsafe { nux_operation_result_free(result) };
        }
    }

    #[test]
    fn surface_dispositions_are_stable_c_abi_values() {
        assert_eq!(NUX_SURFACE_DISPOSITION_NONE, 0);
        assert_eq!(NUX_SURFACE_DISPOSITION_PRESENTED, 1);
        assert_eq!(NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT, 3);
        assert_eq!(NUX_SURFACE_DISPOSITION_RECREATED, 6);
        assert_eq!(NUX_SURFACE_DISPOSITION_FATAL, 9);
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn centered_contain_transform_scales_and_letterboxes_the_artboard() {
        assert_eq!(
            centered_contain_transform(0.0, 0.0, 100.0, 50.0, 300, 300)
                .expect("valid contain transform"),
            Mat2D([3.0, 0.0, 0.0, 3.0, 0.0, 75.0])
        );
        assert_eq!(
            centered_contain_transform(0.0, 0.0, 100.0, 200.0, 300, 300)
                .expect("valid contain transform"),
            Mat2D([1.5, 0.0, 0.0, 1.5, 75.0, 0.0])
        );
        assert_eq!(
            centered_contain_transform(10.0, -5.0, 100.0, 50.0, 300, 300)
                .expect("valid offset contain transform"),
            Mat2D([3.0, 0.0, 0.0, 3.0, -30.0, 90.0])
        );
        assert!(centered_contain_transform(0.0, 0.0, 0.0, 50.0, 300, 300).is_err());
        assert!(centered_contain_transform(0.0, 0.0, 100.0, f32::NAN, 300, 300).is_err());
    }

    #[test]
    fn every_c_export_opens_with_the_panic_firewall() {
        let source = include_str!("lib.rs");
        let mut checked = 0usize;
        for prefix in ["pub unsafe extern \"C\" fn ", "pub extern \"C\" fn "] {
            for (index, _) in source.match_indices(prefix) {
                let rest = &source[index..];
                let body_start = rest.find('{').expect("extern function body");
                let body = rest[body_start + 1..].trim_start();
                let name_end = rest.find('(').expect("extern function parameters");
                let name = &rest[prefix.len()..name_end];
                assert!(
                    body.starts_with("ffi_guard(") || body.starts_with("ffi_guard_with_result("),
                    "extern C function `{name}` bypasses the panic firewall"
                );
                checked = checked.saturating_add(1);
            }
        }
        assert_eq!(
            checked, 22,
            "update the firewall audit for every new export"
        );
    }

    #[test]
    fn panic_firewall_converts_panics_to_the_declared_fallback() {
        assert_eq!(
            ffi_guard(NuxStatus::RuntimeError, || -> NuxStatus {
                panic!("deliberate ABI panic probe")
            }),
            NuxStatus::RuntimeError
        );
        ffi_guard((), || panic!("deliberate void ABI panic probe"));

        let poisoned = std::cell::Cell::new(false);
        let mut result = ptr::null_mut();
        assert_eq!(
            ffi_guard_with_result(
                &mut result,
                || poisoned.set(true),
                || -> NuxStatus { panic!("deliberate operation ABI panic probe") },
            ),
            NuxStatus::RuntimeError
        );
        assert!(poisoned.get());
        assert!(!result.is_null());
        assert_eq!(
            unsafe { nux_operation_result_status(result) },
            NuxStatus::RuntimeError
        );
        let mut diagnostic = NuxByteView::default();
        assert_eq!(
            unsafe { nux_operation_result_diagnostic(result, &mut diagnostic) },
            NuxStatus::Ok
        );
        let diagnostic = unsafe { slice::from_raw_parts(diagnostic.data, diagnostic.len as usize) };
        assert_eq!(diagnostic, PANIC_DIAGNOSTIC.as_bytes());
        unsafe { nux_operation_result_free(result) };
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn runtime_state_is_confined_to_one_worker_thread_across_callers() {
        let worker = product_fixture_worker();
        let caller_thread_id = thread::current().id();
        let owner_thread_id = worker
            .probe_thread_id()
            .expect("worker thread must answer a confinement probe");
        assert_ne!(owner_thread_id, caller_thread_id);

        let mut callers = Vec::new();
        for _ in 0..4 {
            let worker = Arc::clone(&worker);
            callers.push(thread::spawn(move || worker.probe_thread_id()));
        }
        for caller in callers {
            let observed = caller
                .join()
                .expect("probe caller must not panic")
                .expect("worker must answer every probe");
            assert_eq!(observed, owner_thread_id);
        }
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn worker_job_panics_poison_the_session_and_return_an_owned_diagnostic() {
        let worker = product_fixture_worker();
        let session_id = match worker.call(None, |state| state.create_session(None, None)) {
            Ok(Ok(session_id)) => session_id,
            _ => panic!("fixture must create a default render session"),
        };
        let panic_result = worker.call(Some(session_id), |_| -> () {
            panic!("deliberate worker panic probe");
        });
        assert_eq!(panic_result, Err(WorkerCallError::Panicked));

        let session_health = worker
            .call(Some(session_id), move |state| {
                state.require_live_session(session_id)
            })
            .expect("worker must remain available after a caught job panic");
        let failure = match session_health {
            Ok(()) => panic!("panicking session must be poisoned"),
            Err(failure) => failure,
        };
        assert_eq!(failure.status, NuxStatus::RuntimeError);
        assert_eq!(failure.diagnostic, PANIC_DIAGNOSTIC);

        let mut result = ptr::null_mut();
        assert_eq!(
            write_worker_call_failure(&mut result, WorkerCallError::Panicked),
            NuxStatus::RuntimeError
        );
        let mut diagnostic = NuxByteView::default();
        assert_eq!(
            unsafe { nux_operation_result_diagnostic(result, &mut diagnostic) },
            NuxStatus::Ok
        );
        let diagnostic = unsafe { slice::from_raw_parts(diagnostic.data, diagnostic.len as usize) };
        assert_eq!(diagnostic, PANIC_DIAGNOSTIC.as_bytes());
        unsafe { nux_operation_result_free(result) };
    }

    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    #[test]
    fn render_factory_is_session_owned_before_and_after_surface_attachment() {
        let worker = product_fixture_worker();
        let session_id = match worker.call(None, |state| state.create_session(None, None)) {
            Ok(Ok(session_id)) => session_id,
            _ => panic!("fixture must create a default render session"),
        };
        let factory_address = worker
            .call(Some(session_id), move |state| {
                state
                    .session_mut(session_id)
                    .map(|session| (&mut *session.factory as *mut WgpuFactory).addr())
            })
            .expect("worker must inspect the session factory")
            .expect("session factory must exist before surface attachment");

        let surface_id = match worker.call(Some(session_id), move |state| {
            state.attach_surface(session_id, 8, 8)
        }) {
            Ok(Ok(surface_id)) => surface_id,
            _ => panic!("fixture must attach logical Apple presentation state"),
        };
        let attached_factory_address = worker
            .call(Some(session_id), move |state| {
                state
                    .session_mut(session_id)
                    .map(|session| (&mut *session.factory as *mut WgpuFactory).addr())
            })
            .expect("worker must inspect the attached session factory")
            .expect("session factory must remain available after attachment");
        assert_eq!(attached_factory_address, factory_address);

        worker
            .call(Some(session_id), move |state| {
                state.remove_surface(session_id, surface_id)
            })
            .expect("worker must detach logical Apple presentation state");
        let detached_factory_address = worker
            .call(Some(session_id), move |state| {
                state
                    .session_mut(session_id)
                    .map(|session| (&mut *session.factory as *mut WgpuFactory).addr())
            })
            .expect("worker must inspect the detached session factory")
            .expect("session factory must survive surface detachment");
        assert_eq!(detached_factory_address, factory_address);
    }

    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    #[test]
    fn device_loss_reattach_transactionally_recovers_one_session_and_refreshes_the_shared_base() {
        autoreleasepool(|_| {
            let worker = product_fixture_worker();
            let create_session =
                || match worker.call(None, |state| state.create_session(None, None)) {
                    Ok(Ok(session_id)) => session_id,
                    _ => panic!("fixture must create a render session"),
                };
            let affected_id = create_session();
            let sibling_id = create_session();
            let attach_surface = |session_id| match worker.call(Some(session_id), move |state| {
                state.attach_surface(session_id, 8, 8)
            }) {
                Ok(Ok(surface_id)) => surface_id,
                _ => panic!("fixture must attach logical Apple presentation state"),
            };
            let affected_surface_id = attach_surface(affected_id);
            let sibling_surface_id = attach_surface(sibling_id);

            let affected_token = Arc::new(SessionToken {
                worker: Arc::clone(&worker),
                id: affected_id,
            });
            let affected_session = Box::into_raw(Box::new(ScreenSessionHandle {
                token: Arc::clone(&affected_token),
            }))
            .cast::<NuxScreenSession>();
            let affected_surface = Box::into_raw(Box::new(AppleSurfaceHandle {
                token: Arc::new(SurfaceToken {
                    session: Arc::clone(&affected_token),
                    id: affected_surface_id,
                }),
            }))
            .cast::<NuxAppleSurface>();

            let sibling_token = Arc::new(SessionToken {
                worker: Arc::clone(&worker),
                id: sibling_id,
            });
            let sibling_session = Box::into_raw(Box::new(ScreenSessionHandle {
                token: Arc::clone(&sibling_token),
            }))
            .cast::<NuxScreenSession>();
            let sibling_surface = Box::into_raw(Box::new(AppleSurfaceHandle {
                token: Arc::new(SurfaceToken {
                    session: Arc::clone(&sibling_token),
                    id: sibling_surface_id,
                }),
            }))
            .cast::<NuxAppleSurface>();

            let configure_layer = |surface: *const NuxAppleSurface| {
                let mut metal_device = ptr::null_mut();
                let mut result = ptr::null_mut();
                assert_eq!(
                    unsafe {
                        nux_apple_surface_copy_metal_device(surface, &mut metal_device, &mut result)
                    },
                    NuxStatus::Ok
                );
                unsafe { nux_operation_result_free(result) };
                let metal_device: Retained<ProtocolObject<dyn MTLDevice>> = unsafe {
                    Retained::from_raw(metal_device.cast())
                        .expect("copy_metal_device returns a retained device")
                };
                let layer = CAMetalLayer::new();
                layer.setDevice(Some(&metal_device));
                layer.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
                layer.setFramebufferOnly(true);
                layer.setAllowsNextDrawableTimeout(true);
                layer.setDrawableSize(CGSize::new(8.0, 8.0));
                layer
            };
            let sibling_layer = configure_layer(sibling_surface);

            let mut operation = NuxFrameOperation {
                struct_size: size_u32::<NuxFrameOperation>(),
                elapsed_seconds: 0.25,
                render: false,
                apple_drawable: ptr::null_mut(),
                completion_context: ptr::null_mut(),
                completion_callback: None,
            };
            let mut result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(affected_session, &operation, &mut result) },
                NuxStatus::Ok
            );
            unsafe { nux_operation_result_free(result) };

            let (
                factory_address,
                screen_session_address,
                original_generation,
                original_gpu_generation,
            ) = worker
                .call(Some(affected_id), move |state| {
                    let gpu_generation = state.gpu_generation;
                    let session = state.session_mut(affected_id)?;
                    session.injected_device_loss = true;
                    Ok::<_, RuntimeFailure>((
                        (&mut *session.factory as *mut WgpuFactory).addr(),
                        std::ptr::addr_of_mut!(session.screen_session).addr(),
                        session.renderer_generation,
                        gpu_generation,
                    ))
                })
                .expect("worker accepts the test-only device-loss seam")
                .expect("affected session remains live before loss");
            let sibling_generation = worker
                .call(Some(sibling_id), move |state| {
                    state
                        .session(sibling_id)
                        .map(|session| session.renderer_generation)
                })
                .expect("worker inspects sibling generation")
                .expect("sibling remains live");
            assert_eq!(sibling_generation, original_generation);

            operation.elapsed_seconds = 0.5;
            operation.render = true;
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(affected_session, &operation, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_DEVICE_LOST
            );
            unsafe { nux_operation_result_free(result) };

            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_apple_surface_detach(affected_surface, &mut result) },
                NuxStatus::Ok
            );
            unsafe { nux_operation_result_free(result) };

            let mut descriptor = NuxAppleSurfaceDescriptor {
                struct_size: size_u32::<NuxAppleSurfaceDescriptor>(),
                pixel_width: u32::MAX,
                pixel_height: 8,
            };
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_apple_surface_reattach(affected_surface, &descriptor, &mut result) },
                NuxStatus::SurfaceError
            );
            unsafe { nux_operation_result_free(result) };
            worker
                .call(Some(affected_id), move |state| {
                    let gpu_generation = state.gpu_generation;
                    let session = state.session_mut(affected_id)?;
                    assert_eq!(
                        (&mut *session.factory as *mut WgpuFactory).addr(),
                        factory_address
                    );
                    assert_eq!(
                        std::ptr::addr_of_mut!(session.screen_session).addr(),
                        screen_session_address
                    );
                    assert_eq!(session.renderer_generation, original_generation);
                    assert_eq!(gpu_generation, original_gpu_generation);
                    assert_eq!(session.legacy_timestamp_seconds, 0.25);
                    assert!(session.injected_device_loss);
                    assert!(!session.is_fatal);
                    assert!(
                        session
                            .attachment
                            .as_ref()
                            .is_some_and(|attachment| !attachment.surface.is_attached())
                    );
                    Ok::<(), RuntimeFailure>(())
                })
                .expect("worker inspects failed recovery")
                .expect("failed recovery leaves the session retryable");

            descriptor.pixel_width = 8;
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_apple_surface_reattach(affected_surface, &descriptor, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_RECREATED
            );
            unsafe { nux_operation_result_free(result) };
            let recovered_generation = original_gpu_generation
                .checked_add(1)
                .expect("the fixture has generation capacity");
            worker
                .call(Some(affected_id), move |state| {
                    let gpu_generation = state.gpu_generation;
                    let session = state.session_mut(affected_id)?;
                    assert_eq!(
                        (&mut *session.factory as *mut WgpuFactory).addr(),
                        factory_address
                    );
                    assert_eq!(
                        std::ptr::addr_of_mut!(session.screen_session).addr(),
                        screen_session_address
                    );
                    assert_eq!(session.legacy_timestamp_seconds, 0.25);
                    assert_eq!(session.renderer_generation, recovered_generation);
                    assert_eq!(gpu_generation, recovered_generation);
                    assert!(!session.injected_device_loss);
                    assert!(!session.is_fatal);
                    Ok::<(), RuntimeFailure>(())
                })
                .expect("worker inspects successful recovery")
                .expect("successful recovery keeps the logical session live");

            let affected_layer = configure_layer(affected_surface);
            let affected_drawable = affected_layer
                .nextDrawable()
                .expect("recovered layer provides a drawable");
            operation.apple_drawable = Retained::as_ptr(&affected_drawable)
                .cast_mut()
                .cast::<c_void>();
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(affected_session, &operation, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_PRESENTED
            );
            unsafe { nux_operation_result_free(result) };

            let sibling_drawable = sibling_layer
                .nextDrawable()
                .expect("the existing sibling's old domain remains usable");
            operation.apple_drawable = Retained::as_ptr(&sibling_drawable)
                .cast_mut()
                .cast::<c_void>();
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(sibling_session, &operation, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_PRESENTED
            );
            unsafe { nux_operation_result_free(result) };
            let sibling_stayed_on_old_generation = worker
                .call(Some(sibling_id), move |state| {
                    state
                        .session(sibling_id)
                        .map(|session| session.renderer_generation == original_generation)
                })
                .expect("worker inspects the sibling after recovery")
                .expect("sibling remains live");
            assert!(sibling_stayed_on_old_generation);

            let new_session_id = create_session();
            let new_session_uses_refreshed_base = worker
                .call(Some(new_session_id), move |state| {
                    state
                        .session(new_session_id)
                        .map(|session| session.renderer_generation == recovered_generation)
                })
                .expect("worker inspects the post-recovery session")
                .expect("post-recovery session remains live");
            assert!(new_session_uses_refreshed_base);
            worker
                .call(None, move |state| state.remove_session(new_session_id))
                .expect("worker removes the post-recovery session");

            unsafe {
                nux_apple_surface_free(sibling_surface);
                nux_screen_session_free(sibling_session);
                nux_apple_surface_free(affected_surface);
                nux_screen_session_free(affected_session);
            }
        });
    }

    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    #[test]
    fn token_destruction_finishes_surface_and_session_cleanup_before_returning() {
        let worker = product_fixture_worker();
        let session_id = match worker.call(None, |state| state.create_session(None, None)) {
            Ok(Ok(session_id)) => session_id,
            _ => panic!("fixture must create a default render session"),
        };
        let surface_id = match worker.call(Some(session_id), move |state| {
            state.attach_surface(session_id, 8, 8)
        }) {
            Ok(Ok(surface_id)) => surface_id,
            _ => panic!("fixture must attach logical Apple presentation state"),
        };
        let session = Arc::new(SessionToken {
            worker: Arc::clone(&worker),
            id: session_id,
        });
        let surface = Arc::new(SurfaceToken {
            session: Arc::clone(&session),
            id: surface_id,
        });

        drop(surface);

        let surface_is_gone = worker
            .call(None, move |state| {
                state
                    .session(session_id)
                    .is_ok_and(|session| session.attachment.is_none())
            })
            .expect("worker must confirm synchronous surface cleanup");
        assert!(surface_is_gone);

        drop(session);

        let session_is_gone = worker
            .call(None, move |state| !state.sessions.contains_key(&session_id))
            .expect("worker must confirm synchronous session cleanup");
        assert!(session_is_gone);
    }

    #[cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]
    #[test]
    fn public_c_abi_renders_to_cametal_layer_and_preserves_parent_first_ownership() {
        autoreleasepool(|_| {
            let bytes = product_fixture_bytes();
            let request = signed_import_request(&bytes);
            let mut context = ptr::null_mut();
            let mut result = ptr::null_mut();
            let status = unsafe {
                nux_experience_context_create_bound(
                    runtime_binding(),
                    &request.request,
                    &mut context,
                    &mut result,
                )
            };
            assert_eq!(status, NuxStatus::Ok, "{}", unsafe {
                operation_result_message(result)
            });
            unsafe { nux_operation_result_free(result) };

            let session_descriptor = NuxScreenSessionDescriptor {
                struct_size: size_u32::<NuxScreenSessionDescriptor>(),
                artboard_name: NuxByteView::default(),
                state_machine_name: NuxByteView::default(),
            };
            let mut session = ptr::null_mut();
            result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_create(
                        context,
                        &session_descriptor,
                        &mut session,
                        &mut result,
                    )
                },
                NuxStatus::Ok
            );
            unsafe { nux_operation_result_free(result) };

            let layer = CAMetalLayer::new();
            let mut surface_descriptor = NuxAppleSurfaceDescriptor {
                struct_size: size_u32::<NuxAppleSurfaceDescriptor>(),
                pixel_width: 8,
                pixel_height: 8,
            };
            let mut surface = ptr::null_mut();
            result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_screen_session_attach_apple_surface(
                        session,
                        &surface_descriptor,
                        &mut surface,
                        &mut result,
                    )
                },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_RECREATED
            );
            unsafe { nux_operation_result_free(result) };

            let mut metal_device = ptr::null_mut();
            result = ptr::null_mut();
            assert_eq!(
                unsafe {
                    nux_apple_surface_copy_metal_device(surface, &mut metal_device, &mut result)
                },
                NuxStatus::Ok
            );
            assert!(!metal_device.is_null());
            unsafe { nux_operation_result_free(result) };
            let metal_device: Retained<ProtocolObject<dyn MTLDevice>> = unsafe {
                Retained::from_raw(metal_device.cast())
                    .expect("copy_metal_device must return a +1 MTLDevice")
            };
            layer.setDevice(Some(&metal_device));
            layer.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
            layer.setFramebufferOnly(true);
            layer.setAllowsNextDrawableTimeout(true);
            layer.setDrawableSize(CGSize::new(8.0, 8.0));

            let no_drawable_operation = NuxFrameOperation {
                struct_size: size_u32::<NuxFrameOperation>(),
                elapsed_seconds: 0.0,
                render: true,
                apple_drawable: ptr::null_mut(),
                completion_context: ptr::null_mut(),
                completion_callback: None,
            };
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(session, &no_drawable_operation, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_SKIPPED_TIMEOUT
            );
            unsafe { nux_operation_result_free(result) };
            let session_handle = unsafe { &*session.cast::<ScreenSessionHandle>() };
            let session_id = session_handle.token.id;
            let render_attempts = session_handle
                .token
                .worker
                .call(Some(session_id), move |state| {
                    state
                        .session(session_id)
                        .map(|session| session.render_attempts)
                })
                .expect("worker must report render attempts")
                .expect("render session must remain live");
            assert_eq!(
                render_attempts, 0,
                "a missing drawable must skip frame construction and drawing"
            );

            let drawable = layer
                .nextDrawable()
                .expect("configured CAMetalLayer must provide a drawable");
            let drawable_pointer = Retained::as_ptr(&drawable).cast_mut().cast::<c_void>();
            let invalid_operation = NuxFrameOperation {
                struct_size: size_u32::<NuxFrameOperation>(),
                elapsed_seconds: 0.0,
                render: false,
                apple_drawable: drawable_pointer,
                completion_context: ptr::null_mut(),
                completion_callback: None,
            };
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(session, &invalid_operation, &mut result) },
                NuxStatus::InvalidArgument
            );
            unsafe { nux_operation_result_free(result) };

            let completed = AtomicBool::new(false);
            let mut operation = NuxFrameOperation {
                struct_size: size_u32::<NuxFrameOperation>(),
                elapsed_seconds: 0.0,
                render: true,
                apple_drawable: drawable_pointer,
                completion_context: (&completed as *const AtomicBool).cast_mut().cast(),
                completion_callback: Some(mark_frame_completed),
            };
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(session, &operation, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_PRESENTED
            );
            unsafe { nux_operation_result_free(result) };
            wait_for_frame_completion(&completed);
            operation.completion_context = ptr::null_mut();
            operation.completion_callback = None;

            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_apple_surface_resize(surface, 0, 0, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_SKIPPED_ZERO_SIZE
            );
            unsafe { nux_operation_result_free(result) };

            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_apple_surface_detach(surface, &mut result) },
                NuxStatus::Ok
            );
            unsafe { nux_operation_result_free(result) };

            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(session, &no_drawable_operation, &mut result) },
                NuxStatus::SurfaceError,
                "a detached surface must fail before considering zero size or drawable availability"
            );
            unsafe { nux_operation_result_free(result) };

            surface_descriptor.pixel_width = 16;
            surface_descriptor.pixel_height = 12;
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_apple_surface_reattach(surface, &surface_descriptor, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_RECREATED
            );
            unsafe { nux_operation_result_free(result) };

            layer.setDrawableSize(CGSize::new(16.0, 12.0));
            let reattached_drawable = layer
                .nextDrawable()
                .expect("reattached CAMetalLayer must provide a drawable");
            operation.apple_drawable = Retained::as_ptr(&reattached_drawable)
                .cast_mut()
                .cast::<c_void>();
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_screen_session_advance(session, &operation, &mut result) },
                NuxStatus::Ok
            );
            assert_eq!(
                unsafe { nux_operation_result_surface_disposition(result) },
                NUX_SURFACE_DISPOSITION_PRESENTED
            );
            unsafe { nux_operation_result_free(result) };

            unsafe {
                // The public ownership contract allows children to outlive
                // their C parent handles. The surface retains both parents.
                nux_experience_context_free(context);
                nux_screen_session_free(session);
            }
            result = ptr::null_mut();
            assert_eq!(
                unsafe { nux_apple_surface_resize(surface, 20, 10, &mut result) },
                NuxStatus::Ok
            );
            unsafe {
                nux_operation_result_free(result);
                nux_apple_surface_free(surface);
            }
        });
    }

    #[cfg(feature = "apple-product")]
    #[test]
    fn context_import_session_advance_and_parent_first_teardown_use_the_product_handles() {
        let bytes = product_fixture_bytes();
        let request = signed_import_request(&bytes);
        let mut context = ptr::null_mut();
        let mut result = ptr::null_mut();
        let status = unsafe {
            nux_experience_context_create_bound(
                runtime_binding(),
                &request.request,
                &mut context,
                &mut result,
            )
        };
        assert_eq!(status, NuxStatus::Ok, "{}", unsafe {
            operation_result_message(result)
        });
        assert!(!context.is_null());
        assert_eq!(
            unsafe { nux_operation_result_status(result) },
            NuxStatus::Ok
        );
        unsafe { nux_operation_result_free(result) };

        let artboard_name = b"artboard to nest";
        let state_machine_name = b"State Machine 1";
        let named_descriptor = NuxScreenSessionDescriptor {
            struct_size: size_u32::<NuxScreenSessionDescriptor>(),
            artboard_name: NuxByteView {
                data: artboard_name.as_ptr(),
                len: artboard_name.len() as u64,
            },
            state_machine_name: NuxByteView {
                data: state_machine_name.as_ptr(),
                len: state_machine_name.len() as u64,
            },
        };
        let mut named_session = ptr::null_mut();
        result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_create(
                    context,
                    &named_descriptor,
                    &mut named_session,
                    &mut result,
                )
            },
            NuxStatus::Ok
        );
        unsafe {
            nux_operation_result_free(result);
            nux_screen_session_free(named_session);
        }

        let missing_name = b"missing artboard";
        let missing_descriptor = NuxScreenSessionDescriptor {
            struct_size: size_u32::<NuxScreenSessionDescriptor>(),
            artboard_name: NuxByteView {
                data: missing_name.as_ptr(),
                len: missing_name.len() as u64,
            },
            state_machine_name: NuxByteView::default(),
        };
        named_session = ptr::null_mut();
        result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_create(
                    context,
                    &missing_descriptor,
                    &mut named_session,
                    &mut result,
                )
            },
            NuxStatus::NotFound
        );
        assert!(named_session.is_null());
        assert_eq!(
            unsafe { nux_operation_result_status(result) },
            NuxStatus::NotFound
        );
        unsafe { nux_operation_result_free(result) };

        let descriptor = NuxScreenSessionDescriptor {
            struct_size: size_u32::<NuxScreenSessionDescriptor>(),
            artboard_name: NuxByteView::default(),
            state_machine_name: NuxByteView::default(),
        };
        let mut session = ptr::null_mut();
        result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_create(context, &descriptor, &mut session, &mut result) },
            NuxStatus::Ok
        );
        assert!(!session.is_null());
        unsafe {
            nux_operation_result_free(result);
            // Child handles retain their parents, so Swift teardown ordering
            // cannot turn a live session into a dangling reference.
            nux_experience_context_free(context);
        }

        let operation = NuxFrameOperation {
            struct_size: size_u32::<NuxFrameOperation>(),
            elapsed_seconds: 0.016,
            render: false,
            apple_drawable: ptr::null_mut(),
            completion_context: ptr::null_mut(),
            completion_callback: None,
        };
        result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_advance(session, &operation, &mut result) },
            NuxStatus::Ok
        );
        assert_eq!(
            unsafe { nux_operation_result_status(result) },
            NuxStatus::Ok
        );
        unsafe {
            nux_operation_result_free(result);
            nux_screen_session_free(session);
        }
    }
}
