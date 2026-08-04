//! Repeated package import / render / free cycles across the SDK's own signed
//! `.nux` fixtures, driven through the public C ABI exactly as the Apple host
//! drives it.
//!
//! Regression cover for [UNIV-1397]: the Apple native corpus aborted during the
//! package lifecycle, and the seam had no test that took a *real* signed
//! package all the way through import -> screen session -> Apple surface ->
//! Metal device -> presented frames -> parent-first teardown, repeatedly.
//!
//! The `scripted-resources` fixture is the load-bearing one: a screen session
//! for a scripted package can only bootstrap when the session hands scripts a
//! retained `PersistentFactory` renderer domain. Binding the session to a
//! plain `Box<WgpuFactory>` refuses bootstrap with "scripted files require a
//! PersistentFactory renderer context", which this test fails on.
//!
//! Metal is required, so this is gated to Apple targets with `apple-product`.

#![cfg(all(feature = "apple-product", any(target_os = "ios", target_os = "macos")))]

use nux_apple_runtime::*;
use nux_container::{AssetLocation, read_package};
use objc2::rc::{Retained, autoreleasepool};
use objc2::runtime::ProtocolObject;
use objc2_core_foundation::CGSize;
use objc2_metal::{MTLDevice, MTLPixelFormat};
use objc2_quartz_core::CAMetalLayer;
use std::ffi::{CString, c_void};
use std::path::{Path, PathBuf};
use std::ptr;

/// Lifecycles per fixture screen. Repetition is the point: a single pass never
/// reproduced the reported corruption.
const CYCLES_PER_SCREEN: usize = 3;
/// Presented frames per lifecycle.
const FRAMES_PER_CYCLE: usize = 4;
const SURFACE_EDGE_PIXELS: u32 = 192;

/// The committed fixtures are signed by the parent repository's E2E harness
/// with its deterministic test-only development key, so the trust root is that
/// key's public half rather than anything this crate derives.
const FIXTURE_SIGNING_KEY_ID: &str = "TEST_ONLY_DEV_KEYPAIR";
const FIXTURE_SIGNING_PUBLIC_KEY: [u8; 32] = [
    0x21, 0x52, 0xf8, 0xd1, 0x9b, 0x79, 0x1d, 0x24, 0x45, 0x32, 0x42, 0xe1, 0x5f, 0x2e, 0xab, 0x6c,
    0xb7, 0xcf, 0xfa, 0x7b, 0x6a, 0x5e, 0xd3, 0x00, 0x97, 0x96, 0x0e, 0x06, 0x98, 0x81, 0xdb, 0x12,
];

fn size_u32<T>() -> u32 {
    u32::try_from(std::mem::size_of::<T>()).expect("ABI struct fits u32")
}

fn view(bytes: &[u8]) -> NuxByteView {
    NuxByteView {
        data: bytes.as_ptr(),
        len: bytes.len() as u64,
    }
}

/// The committed SDK fixtures, unless `NUX_FIXTURE_ROOT` points elsewhere.
///
/// The override exists so this test can be replayed against another corpus of
/// the same shape — in particular the parent repository's published editor
/// corpus, which is what the failing Apple consumer actually consumes.
fn fixture_root() -> PathBuf {
    if let Ok(override_root) = std::env::var("NUX_FIXTURE_ROOT") {
        return PathBuf::from(override_root);
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("Tests/ExperienceRuntimeHostApp/Fixtures")
}

fn runtime_binding() -> *const NuxRuntimeBinding {
    let version = env!("CARGO_PKG_VERSION");
    let revision = env!("NUX_RUNTIME_SOURCE_REVISION");
    let mut binding = ptr::null();
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
        NUX_STATUS_OK,
        "the linked runtime identity must bind"
    );
    binding
}

/// Storage every borrowed view in the import request points into.
struct ImportRequest {
    request: NuxExperienceImportRequest,
    _package: Vec<u8>,
    _experience_id: CString,
    _build_id: CString,
    _key_id: Vec<u8>,
    // Heap-backed on purpose: the request holds a `NuxByteView` into these
    // bytes, so their address must survive this struct being moved.
    _public_key: Vec<u8>,
    _keys: Vec<NuxExperienceAuthorizationKey>,
    _assets: Vec<NuxExperienceExternalAsset>,
    _asset_storage: Vec<ExternalAssetStorage>,
}

struct ExternalAssetStorage {
    unique_name: Vec<u8>,
    source_key: Vec<u8>,
    expected_sha256: Vec<u8>,
    bytes: Vec<u8>,
}

struct ScreenPlan {
    artboard_name: String,
    screen_id: String,
}

/// Builds the import request the Apple host would build for one fixture:
/// package bytes, the trusted signing key, and every declared external asset
/// resolved from the fixture's content-addressed `assets/` directory.
fn build_import_request(fixture_root: &Path) -> (ImportRequest, Vec<ScreenPlan>) {
    let package_path = fixture_root.join("experience.nux");
    let package = std::fs::read(&package_path)
        .unwrap_or_else(|error| panic!("fixture {package_path:?} must be readable: {error}"));
    let manifest = read_package(&package)
        .expect("SDK fixture package decodes")
        .manifest()
        .clone();

    let screens = manifest
        .screens
        .iter()
        .map(|screen| ScreenPlan {
            artboard_name: screen.artboard_name.clone(),
            screen_id: screen.screen_id.clone(),
        })
        .collect::<Vec<_>>();

    let declarations = manifest
        .assets
        .images
        .iter()
        .map(|image| {
            (
                NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_IMAGE,
                image.rive_asset_id,
                image.required,
                &image.location,
                image.rive_unique_name.as_str(),
                image.sha256.as_str(),
                image.size_bytes,
            )
        })
        .chain(manifest.assets.fonts.iter().map(|font| {
            (
                NUX_EXPERIENCE_EXTERNAL_ASSET_KIND_FONT,
                font.rive_asset_id,
                font.required,
                &font.location,
                font.rive_unique_name.as_str(),
                font.sha256.as_str(),
                font.size_bytes,
            )
        }));

    let mut asset_storage = Vec::new();
    let mut descriptors = Vec::new();
    for (kind, rive_asset_id, required, location, unique_name, sha256, size_bytes) in declarations {
        let AssetLocation::External { key } = location else {
            continue;
        };
        let asset_path = fixture_root.join(key);
        let bytes = std::fs::read(&asset_path).unwrap_or_default();
        let provided = !bytes.is_empty() && bytes.len() as u64 == size_bytes;
        assert!(
            provided || !required,
            "required external asset {asset_path:?} must be present in the fixture"
        );
        asset_storage.push(ExternalAssetStorage {
            unique_name: unique_name.as_bytes().to_vec(),
            source_key: key.as_bytes().to_vec(),
            expected_sha256: sha256.as_bytes().to_vec(),
            bytes: if provided { bytes } else { Vec::new() },
        });
        let asset_id = u32::try_from(rive_asset_id).expect("fixture asset id fits the ABI");
        descriptors.push((kind, asset_id, required, provided));
    }

    let assets = descriptors
        .iter()
        .zip(asset_storage.iter())
        .map(
            |((kind, asset_id, required, provided), storage)| NuxExperienceExternalAsset {
                struct_size: size_u32::<NuxExperienceExternalAsset>(),
                kind: *kind,
                asset_id: *asset_id,
                required: *required,
                provided: *provided,
                unique_name: view(&storage.unique_name),
                source_key: view(&storage.source_key),
                expected_sha256: view(&storage.expected_sha256),
                bytes: view(&storage.bytes),
            },
        )
        .collect::<Vec<_>>();

    let experience_id =
        CString::new(manifest.identity.experience_id.clone()).expect("experience identity");
    let build_id = CString::new(manifest.identity.build_id.clone()).expect("build identity");
    let key_id = FIXTURE_SIGNING_KEY_ID.as_bytes().to_vec();
    let public_key = FIXTURE_SIGNING_PUBLIC_KEY.to_vec();
    let keys = vec![NuxExperienceAuthorizationKey {
        struct_size: size_u32::<NuxExperienceAuthorizationKey>(),
        key_id: view(&key_id),
        ed25519_public_key: view(&public_key),
    }];

    let request = NuxExperienceImportRequest {
        struct_size: size_u32::<NuxExperienceImportRequest>(),
        package_bytes: view(&package),
        expected_experience_id: experience_id.as_ptr(),
        expected_build_id: build_id.as_ptr(),
        candidate_keys: keys.as_ptr(),
        candidate_key_count: keys.len() as u64,
        external_assets: if assets.is_empty() {
            ptr::null()
        } else {
            assets.as_ptr()
        },
        external_asset_count: assets.len() as u64,
    };

    (
        ImportRequest {
            request,
            _package: package,
            _experience_id: experience_id,
            _build_id: build_id,
            _key_id: key_id,
            _public_key: public_key,
            _keys: keys,
            _assets: assets,
            _asset_storage: asset_storage,
        },
        screens,
    )
}

fn diagnostics(result: *mut NuxOperationResult) -> String {
    let count = unsafe { nux_operation_result_diagnostic_count(result) };
    (0..count)
        .filter_map(|index| {
            let mut diagnostic = NuxDiagnosticView::default();
            if unsafe { nux_operation_result_diagnostic_at(result, index, &mut diagnostic) }
                != NUX_STATUS_OK
            {
                return None;
            }
            let message = unsafe {
                std::slice::from_raw_parts(diagnostic.message.data, diagnostic.message.len as usize)
            };
            Some(String::from_utf8_lossy(message).into_owned())
        })
        .collect::<Vec<_>>()
        .join("; ")
}

/// One complete lifecycle for one screen, in the Apple host's order.
fn run_one_cycle(fixture_id: &str, fixture_root: &Path, screen_index: usize) {
    autoreleasepool(|_| {
        let (import, screens) = build_import_request(fixture_root);
        let plan = &screens[screen_index];
        let label = format!("{fixture_id}/{}", plan.screen_id);

        let mut context = ptr::null_mut();
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_experience_context_create_bound(
                    runtime_binding(),
                    &import.request,
                    &mut context,
                    &mut result,
                )
            },
            NUX_STATUS_OK,
            "{label}: package import failed: {}",
            diagnostics(result)
        );
        unsafe { nux_operation_result_free(result) };

        let artboard = plan.artboard_name.as_bytes();
        let descriptor = NuxScreenSessionDescriptor {
            struct_size: size_u32::<NuxScreenSessionDescriptor>(),
            artboard_name: view(artboard),
            state_machine_name: NuxByteView::default(),
        };
        let mut session = ptr::null_mut();
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_create(context, &descriptor, &mut session, &mut result) },
            NUX_STATUS_OK,
            "{label}: screen session creation failed: {}",
            diagnostics(result)
        );
        unsafe { nux_operation_result_free(result) };

        let surface_descriptor = NuxAppleSurfaceDescriptor {
            struct_size: size_u32::<NuxAppleSurfaceDescriptor>(),
            pixel_width: SURFACE_EDGE_PIXELS,
            pixel_height: SURFACE_EDGE_PIXELS,
        };
        let mut surface = ptr::null_mut();
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_attach_apple_surface(
                    session,
                    &surface_descriptor,
                    &mut surface,
                    &mut result,
                )
            },
            NUX_STATUS_OK,
            "{label}: Apple surface attachment failed: {}",
            diagnostics(result)
        );
        unsafe { nux_operation_result_free(result) };

        let mut device_pointer = ptr::null_mut();
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_apple_surface_copy_metal_device(surface, &mut device_pointer, &mut result)
            },
            NUX_STATUS_OK,
            "{label}: Metal device copy failed: {}",
            diagnostics(result)
        );
        unsafe { nux_operation_result_free(result) };
        // The copied device carries +1 ownership, exactly as Swift's
        // `takeRetainedValue` consumes it.
        let metal_device: Retained<ProtocolObject<dyn MTLDevice>> = unsafe {
            Retained::from_raw(device_pointer.cast())
                .expect("copy_metal_device returns a retained device")
        };
        let layer = CAMetalLayer::new();
        layer.setDevice(Some(&metal_device));
        layer.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
        layer.setFramebufferOnly(true);
        layer.setAllowsNextDrawableTimeout(true);
        layer.setDrawableSize(CGSize::new(
            f64::from(SURFACE_EDGE_PIXELS),
            f64::from(SURFACE_EDGE_PIXELS),
        ));

        let mut presented = 0usize;
        for frame in 0..FRAMES_PER_CYCLE {
            autoreleasepool(|_| {
                let Some(drawable) = layer.nextDrawable() else {
                    return;
                };
                let operation = NuxFrameOperation {
                    struct_size: size_u32::<NuxFrameOperation>(),
                    elapsed_seconds: 1.0 / 60.0,
                    render: true,
                    // Borrowed for the synchronous call only, as Swift passes
                    // its main-actor drawable.
                    apple_drawable: Retained::as_ptr(&drawable).cast_mut().cast::<c_void>(),
                    completion_context: ptr::null_mut(),
                    completion_callback: None,
                };
                let mut result = ptr::null_mut();
                assert_eq!(
                    unsafe { nux_screen_session_advance(session, &operation, &mut result) },
                    NUX_STATUS_OK,
                    "{label}: frame {frame} failed: {}",
                    diagnostics(result)
                );
                if unsafe { nux_operation_result_surface_disposition(result) }
                    == NUX_SURFACE_DISPOSITION_PRESENTED
                {
                    presented += 1;
                }
                unsafe { nux_operation_result_free(result) };
            });
        }
        assert!(presented > 0, "{label}: no frame reached presentation");

        // The Apple host's teardown order: surface, session, then context.
        unsafe {
            nux_apple_surface_free(surface);
            nux_screen_session_free(session);
            nux_experience_context_free(context);
        }
    });
}

fn fixture_ids() -> Vec<String> {
    let index_path = fixture_root().join("fixture-index.json");
    let bytes = std::fs::read(&index_path).expect("SDK fixture index must be readable");
    let index: serde_json::Value =
        serde_json::from_slice(&bytes).expect("SDK fixture index parses");
    assert_eq!(
        index["schemaVersion"].as_str(),
        Some("nuxie-sdk-fixtures.v1"),
        "unsupported SDK fixture index"
    );
    index["fixtures"]
        .as_array()
        .expect("fixture index lists fixtures")
        .iter()
        .map(|fixture| {
            fixture["id"]
                .as_str()
                .expect("every fixture declares an id")
                .to_owned()
        })
        .collect()
}

#[test]
fn every_signed_fixture_survives_repeated_import_render_and_free_cycles() {
    let root = fixture_root();
    let ids = fixture_ids();
    assert!(
        ids.iter().any(|id| id == "scripted-resources"),
        "the scripted-resources fixture must stay in the corpus: it is the only \
         cover for the session's persistent renderer-domain contract"
    );

    for id in &ids {
        let fixture_root = root.join(id);
        let (_, screens) = build_import_request(&fixture_root);
        for screen_index in 0..screens.len() {
            for _ in 0..CYCLES_PER_SCREEN {
                run_one_cycle(id, &fixture_root, screen_index);
            }
        }
    }
}

/// Swift releases the previous screen's C handles from an `isolated deinit`,
/// which can run after the next screen has already imported and started
/// rendering, and off the thread that created them. Both contexts are live at
/// once, and the older one is released from another thread.
#[test]
fn overlapping_contexts_survive_off_thread_teardown() {
    struct LiveScreen {
        context: *mut NuxExperienceContext,
        session: *mut NuxScreenSession,
        surface: *mut NuxAppleSurface,
    }
    // The C handles are documented as callable from arbitrary threads, and
    // Swift already releases them off the thread that created them.
    unsafe impl Send for LiveScreen {}

    impl LiveScreen {
        /// The Apple host's teardown order.
        fn teardown(self) {
            unsafe {
                nux_apple_surface_free(self.surface);
                nux_screen_session_free(self.session);
                nux_experience_context_free(self.context);
            }
        }
    }

    let root = fixture_root();
    let mut previous: Option<LiveScreen> = None;
    let mut teardowns = Vec::new();

    for id in fixture_ids() {
        let fixture_root = root.join(&id);
        let (import, screens) = build_import_request(&fixture_root);
        let plan = &screens[0];
        let label = format!("{id}/{}", plan.screen_id);

        let mut context = ptr::null_mut();
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_experience_context_create_bound(
                    runtime_binding(),
                    &import.request,
                    &mut context,
                    &mut result,
                )
            },
            NUX_STATUS_OK,
            "{label}: package import failed: {}",
            diagnostics(result)
        );
        unsafe { nux_operation_result_free(result) };

        let artboard = plan.artboard_name.as_bytes();
        let descriptor = NuxScreenSessionDescriptor {
            struct_size: size_u32::<NuxScreenSessionDescriptor>(),
            artboard_name: view(artboard),
            state_machine_name: NuxByteView::default(),
        };
        let mut session = ptr::null_mut();
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe { nux_screen_session_create(context, &descriptor, &mut session, &mut result) },
            NUX_STATUS_OK,
            "{label}: screen session creation failed: {}",
            diagnostics(result)
        );
        unsafe { nux_operation_result_free(result) };

        let surface_descriptor = NuxAppleSurfaceDescriptor {
            struct_size: size_u32::<NuxAppleSurfaceDescriptor>(),
            pixel_width: SURFACE_EDGE_PIXELS,
            pixel_height: SURFACE_EDGE_PIXELS,
        };
        let mut surface = ptr::null_mut();
        let mut result = ptr::null_mut();
        assert_eq!(
            unsafe {
                nux_screen_session_attach_apple_surface(
                    session,
                    &surface_descriptor,
                    &mut surface,
                    &mut result,
                )
            },
            NUX_STATUS_OK,
            "{label}: Apple surface attachment failed: {}",
            diagnostics(result)
        );
        unsafe { nux_operation_result_free(result) };

        // Release the previous screen only now, off-thread, while this one is
        // still live.
        if let Some(previous) = previous.take() {
            teardowns.push(
                std::thread::Builder::new()
                    .name("nux-univ-1397-teardown".to_owned())
                    // Call through the whole `Send` value so the closure moves
                    // the struct, not its individual raw pointers.
                    .spawn(move || previous.teardown())
                    .expect("teardown thread spawns"),
            );
        }
        previous = Some(LiveScreen {
            context,
            session,
            surface,
        });
    }

    if let Some(previous) = previous.take() {
        previous.teardown();
    }
    for teardown in teardowns {
        teardown.join().expect("teardown thread completes");
    }
}
