//! Apple-owned drawable presentation policy for the retained WebGPU renderer.

use block2::RcBlock;
use nuxie_renderer::{
    RenderMode, RendererError, WgpuDeviceHealth, WgpuExternalDeviceFailureKind, WgpuFactory,
    WgpuFrame, WgpuFrameMetrics, WgpuMetalPresenter,
};
use objc2::rc::Retained;
use objc2::runtime::ProtocolObject;
use objc2_metal::{
    MTLCommandBuffer, MTLCommandBufferError, MTLCommandBufferStatus, MTLCommandQueue, MTLDevice,
    MTLDrawable, MTLPixelFormat, MTLResource, MTLTexture,
};
use objc2_quartz_core::CAMetalDrawable;
#[cfg(test)]
use objc2_quartz_core::CAMetalLayer;
use std::ffi::c_void;
use std::fmt;
use std::ptr::NonNull;
use std::sync::{Arc, Mutex};

type PresentationCallback = Box<dyn FnOnce() + Send + 'static>;

struct PresentationCompletionState {
    callback: Mutex<Option<PresentationCallback>>,
}

impl PresentationCompletionState {
    fn complete(&self) {
        let callback = {
            let mut callback = match self.callback.lock() {
                Ok(callback) => callback,
                Err(poisoned) => poisoned.into_inner(),
            };
            callback.take()
        };
        if let Some(callback) = callback {
            callback();
        }
    }
}

/// One completion that fires exactly once after Metal finishes using a
/// drawable, or immediately when presentation cannot be scheduled.
pub struct ApplePresentationCompletion {
    state: Arc<PresentationCompletionState>,
    armed: bool,
}

impl ApplePresentationCompletion {
    pub fn new(callback: impl FnOnce() + Send + 'static) -> Self {
        Self {
            state: Arc::new(PresentationCompletionState {
                callback: Mutex::new(Some(Box::new(callback))),
            }),
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for ApplePresentationCompletion {
    fn drop(&mut self) {
        if self.armed {
            self.state.complete();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum SurfaceDisposition {
    None = 0,
    Presented = 1,
    SkippedZeroSize = 2,
    SkippedTimeout = 3,
    SkippedOccluded = 4,
    Reconfigured = 5,
    Recreated = 6,
    DeviceLost = 7,
    OutOfMemory = 8,
    Fatal = 9,
}

#[derive(Debug)]
pub enum SurfaceError {
    NullDrawable,
    InvalidDrawable(String),
    Unsupported(&'static str),
    Presentation(&'static str),
    Renderer(RendererError),
}

impl fmt::Display for SurfaceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NullDrawable => formatter.write_str("CAMetalDrawable pointer is null"),
            Self::InvalidDrawable(message) => {
                write!(formatter, "invalid Apple drawable: {message}")
            }
            Self::Unsupported(message) => write!(formatter, "unsupported Apple surface: {message}"),
            Self::Presentation(message) => {
                write!(formatter, "failed to present Apple drawable: {message}")
            }
            Self::Renderer(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for SurfaceError {}

impl From<RendererError> for SurfaceError {
    fn from(error: RendererError) -> Self {
        Self::Renderer(error)
    }
}

pub struct AppleSurface {
    presenter: WgpuMetalPresenter,
    device: Retained<ProtocolObject<dyn MTLDevice>>,
    queue: Retained<ProtocolObject<dyn MTLCommandQueue>>,
    width: u32,
    height: u32,
    attached: bool,
}

impl AppleSurface {
    /// Creates the first renderer domain without touching UIKit-owned state.
    /// Swift configures its `CAMetalLayer` with [`Self::copy_metal_device`] and
    /// acquires each drawable on the main actor.
    pub fn attach_with_factory(
        width: u32,
        height: u32,
        mode: RenderMode,
    ) -> Result<(WgpuFactory, Self), SurfaceError> {
        let mut factory = WgpuFactory::new_with_mode(width.max(1), height.max(1), mode)?;
        let surface = Self::attach(&mut factory, width, height)?;
        Ok((factory, surface))
    }

    /// Creates logical presentation state for a shared renderer domain.
    pub fn attach(
        factory: &mut WgpuFactory,
        width: u32,
        height: u32,
    ) -> Result<Self, SurfaceError> {
        if width != 0 && height != 0 {
            factory.resize(width, height)?;
        }
        let presenter = factory.create_metal_presenter()?;
        let device_pointer = presenter.copy_device()?;
        let device: Retained<ProtocolObject<dyn MTLDevice>> =
            unsafe { Retained::from_raw(device_pointer.cast()) }
                .ok_or(SurfaceError::Unsupported("renderer returned no MTLDevice"))?;
        let queue_pointer = presenter.copy_command_queue()?;
        let queue: Retained<ProtocolObject<dyn MTLCommandQueue>> =
            unsafe { Retained::from_raw(queue_pointer.cast()) }.ok_or(
                SurfaceError::Unsupported("renderer returned no MTLCommandQueue"),
            )?;
        Ok(Self {
            presenter,
            device,
            queue,
            width,
            height,
            attached: true,
        })
    }

    pub fn dimensions(&self) -> (u32, u32) {
        (self.width, self.height)
    }

    pub fn is_attached(&self) -> bool {
        self.attached
    }

    pub fn resize(
        &mut self,
        factory: &mut WgpuFactory,
        width: u32,
        height: u32,
    ) -> Result<SurfaceDisposition, SurfaceError> {
        self.configure_dimensions(factory, width, height)?;
        Ok(if width == 0 || height == 0 {
            SurfaceDisposition::SkippedZeroSize
        } else {
            SurfaceDisposition::Reconfigured
        })
    }

    pub fn detach(&mut self) {
        self.attached = false;
    }

    pub fn reattach(
        &mut self,
        factory: &mut WgpuFactory,
        width: u32,
        height: u32,
    ) -> Result<SurfaceDisposition, SurfaceError> {
        self.configure_dimensions(factory, width, height)?;
        self.attached = true;
        Ok(if width == 0 || height == 0 {
            SurfaceDisposition::SkippedZeroSize
        } else {
            SurfaceDisposition::Recreated
        })
    }

    /// Copies the renderer's `MTLDevice` with Objective-C +1 ownership.
    /// The caller must transfer that ownership to ARC or release it.
    pub fn copy_metal_device(&self) -> *mut c_void {
        Retained::into_raw(self.device.clone()).cast()
    }

    /// Checks whether presentation must fail or can finish without building a frame.
    ///
    /// Callers that can avoid frame construction use this to preserve the same
    /// device-health, attachment, zero-size, and drawable-availability ordering
    /// as [`Self::present`]. `None` means a drawable-backed frame is required.
    pub fn preflight_present(
        &self,
        drawable_available: bool,
    ) -> Result<Option<SurfaceDisposition>, SurfaceError> {
        if let Some(disposition) = device_failure_disposition(&self.presenter)? {
            return Ok(Some(disposition));
        }
        if !self.attached {
            return Err(SurfaceError::Unsupported("surface is not attached"));
        }
        if self.width == 0 || self.height == 0 {
            return Ok(Some(SurfaceDisposition::SkippedZeroSize));
        }
        if !drawable_available {
            return Ok(Some(SurfaceDisposition::SkippedTimeout));
        }
        Ok(None)
    }

    /// Renders and schedules presentation into a main-actor-acquired drawable.
    /// A null drawable is the bounded no-drawable outcome, not an error.
    ///
    /// # Safety
    ///
    /// A non-null pointer must be a live `id<CAMetalDrawable>` retained by the
    /// caller until this synchronous method returns.
    pub unsafe fn present(
        &mut self,
        frame: WgpuFrame,
        drawable: *mut c_void,
        completion: Option<ApplePresentationCompletion>,
    ) -> Result<(SurfaceDisposition, WgpuFrameMetrics), SurfaceError> {
        let mut completion = completion;
        if let Some(disposition) = self.preflight_present(!drawable.is_null())? {
            return Ok((disposition, frame.metrics()));
        }
        let Some(drawable) = NonNull::new(drawable) else {
            return Ok((SurfaceDisposition::SkippedTimeout, frame.metrics()));
        };
        let drawable = unsafe {
            drawable
                .cast::<ProtocolObject<dyn CAMetalDrawable>>()
                .as_ref()
        };
        let texture = validate_drawable_texture(drawable, &self.device, self.width, self.height)?;
        let texture_pointer = Retained::as_ptr(&texture).cast_mut().cast::<c_void>();
        let metrics = unsafe {
            self.presenter
                .render_to_texture(frame, texture_pointer, self.width, self.height)?
        };
        schedule_drawable_presentation(
            &self.queue,
            &self.presenter,
            drawable,
            completion.as_mut(),
        )?;
        if let Some(disposition) = device_failure_disposition(&self.presenter)? {
            return Ok((disposition, metrics));
        }
        Ok((SurfaceDisposition::Presented, metrics))
    }

    fn configure_dimensions(
        &mut self,
        factory: &mut WgpuFactory,
        width: u32,
        height: u32,
    ) -> Result<(), SurfaceError> {
        if width != 0 && height != 0 {
            factory.resize(width, height)?;
        }
        self.width = width;
        self.height = height;
        Ok(())
    }
}

fn device_failure_disposition(
    presenter: &WgpuMetalPresenter,
) -> Result<Option<SurfaceDisposition>, SurfaceError> {
    Ok(match presenter.device_health() {
        WgpuDeviceHealth::Healthy => None,
        WgpuDeviceHealth::DeviceLost => Some(SurfaceDisposition::DeviceLost),
        WgpuDeviceHealth::OutOfMemory => Some(SurfaceDisposition::OutOfMemory),
        WgpuDeviceHealth::Failed(message) => {
            return Err(SurfaceError::Renderer(RendererError::Device(message)));
        }
    })
}

fn validate_drawable_texture(
    drawable: &ProtocolObject<dyn CAMetalDrawable>,
    renderer_device: &ProtocolObject<dyn MTLDevice>,
    expected_width: u32,
    expected_height: u32,
) -> Result<Retained<ProtocolObject<dyn MTLTexture>>, SurfaceError> {
    let raw_texture = drawable.texture();
    let width = u32::try_from(raw_texture.width())
        .map_err(|_| SurfaceError::InvalidDrawable("width exceeds UInt32".to_owned()))?;
    let height = u32::try_from(raw_texture.height())
        .map_err(|_| SurfaceError::InvalidDrawable("height exceeds UInt32".to_owned()))?;
    if (width, height) != (expected_width, expected_height) {
        return Err(SurfaceError::InvalidDrawable(format!(
            "texture is {width}x{height}, expected {expected_width}x{expected_height}"
        )));
    }
    if raw_texture.pixelFormat() != MTLPixelFormat::BGRA8Unorm {
        return Err(SurfaceError::InvalidDrawable(
            "texture format is not BGRA8Unorm".to_owned(),
        ));
    }
    let drawable_device = raw_texture.device();
    if Retained::as_ptr(&drawable_device) != std::ptr::from_ref(renderer_device) {
        return Err(SurfaceError::InvalidDrawable(
            "texture belongs to a different MTLDevice".to_owned(),
        ));
    }

    Ok(raw_texture)
}

fn schedule_drawable_presentation(
    queue: &ProtocolObject<dyn MTLCommandQueue>,
    presenter: &WgpuMetalPresenter,
    drawable: &ProtocolObject<dyn CAMetalDrawable>,
    completion: Option<&mut ApplePresentationCompletion>,
) -> Result<(), SurfaceError> {
    let command_buffer = queue.commandBuffer().ok_or(SurfaceError::Presentation(
        "MTLCommandQueue returned no command buffer",
    ))?;
    let drawable: &ProtocolObject<dyn MTLDrawable> = drawable.as_ref();
    command_buffer.presentDrawable(drawable);
    let completion_state = completion
        .as_ref()
        .map(|completion| Arc::clone(&completion.state));
    let presenter = presenter.clone();
    let completed_handler = RcBlock::new(
        move |command_buffer: NonNull<ProtocolObject<dyn MTLCommandBuffer>>| {
            let command_buffer = unsafe { command_buffer.as_ref() };
            if command_buffer.status() == MTLCommandBufferStatus::Error {
                let error_code = command_buffer.error().map(|error| error.code());
                presenter.record_external_failure(
                    metal_failure_kind(error_code),
                    match error_code {
                        Some(code) => {
                            format!("Metal presentation command buffer failed with code {code}")
                        }
                        None => {
                            "Metal presentation command buffer failed without an NSError".to_owned()
                        }
                    },
                );
            }
            if let Some(completion_state) = &completion_state {
                completion_state.complete();
            }
        },
    );
    unsafe {
        command_buffer.addCompletedHandler(RcBlock::as_ptr(&completed_handler));
    }
    command_buffer.commit();
    if let Some(completion) = completion {
        completion.disarm();
    }
    Ok(())
}

fn metal_failure_kind(error_code: Option<isize>) -> WgpuExternalDeviceFailureKind {
    match error_code.and_then(|code| usize::try_from(code).ok()) {
        Some(code) if code == MTLCommandBufferError::OutOfMemory.0 => {
            WgpuExternalDeviceFailureKind::OutOfMemory
        }
        Some(code) if code == MTLCommandBufferError::DeviceRemoved.0 => {
            WgpuExternalDeviceFailureKind::DeviceLost
        }
        _ => WgpuExternalDeviceFailureKind::Internal,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use objc2::rc::{Retained, autoreleasepool};
    use objc2_core_foundation::CGSize;
    use std::sync::atomic::{AtomicBool, Ordering};

    fn configured_layer(surface: &AppleSurface, width: u32, height: u32) -> Retained<CAMetalLayer> {
        let device_pointer = surface.copy_metal_device();
        let device: Retained<ProtocolObject<dyn MTLDevice>> = unsafe {
            Retained::from_raw(device_pointer.cast()).expect("copied Metal device must be non-null")
        };
        let layer = CAMetalLayer::new();
        layer.setDevice(Some(&device));
        layer.setPixelFormat(MTLPixelFormat::BGRA8Unorm);
        layer.setFramebufferOnly(true);
        layer.setDrawableSize(CGSize::new(width.into(), height.into()));
        layer.setMaximumDrawableCount(2);
        layer.setAllowsNextDrawableTimeout(true);
        layer
    }

    fn wait_for_metal_queue(surface: &AppleSurface) {
        let command_buffer = surface
            .queue
            .commandBuffer()
            .expect("Metal queue must return a command buffer");
        command_buffer.commit();
        command_buffer.waitUntilCompleted();
    }

    #[test]
    fn surface_dispositions_are_stable_fixed_width_values() {
        assert_eq!(SurfaceDisposition::Presented as u8, 1);
        assert_eq!(SurfaceDisposition::SkippedTimeout as u8, 3);
        assert_eq!(SurfaceDisposition::Recreated as u8, 6);
        assert_eq!(SurfaceDisposition::Fatal as u8, 9);
    }

    #[test]
    fn logical_surface_lifecycle_and_resize_are_transactional() {
        let (mut factory, mut surface) =
            AppleSurface::attach_with_factory(8, 8, RenderMode::Msaa).unwrap();
        assert!(surface.is_attached());
        assert_eq!(surface.dimensions(), (8, 8));
        assert_eq!(factory.dimensions(), (8, 8));

        assert_eq!(
            surface.resize(&mut factory, 0, 0).unwrap(),
            SurfaceDisposition::SkippedZeroSize
        );
        assert_eq!(surface.dimensions(), (0, 0));
        assert_eq!(factory.dimensions(), (8, 8));

        assert_eq!(
            surface.resize(&mut factory, 16, 12).unwrap(),
            SurfaceDisposition::Reconfigured
        );
        assert_eq!(surface.dimensions(), (16, 12));
        assert_eq!(factory.dimensions(), (16, 12));

        assert!(matches!(
            surface.resize(&mut factory, u32::MAX, 12),
            Err(SurfaceError::Renderer(
                RendererError::InvalidTextureExtent { .. }
            ))
        ));
        assert_eq!(surface.dimensions(), (16, 12));
        assert_eq!(factory.dimensions(), (16, 12));

        surface.detach();
        assert!(!surface.is_attached());
        assert!(matches!(
            surface.reattach(&mut factory, u32::MAX, 12),
            Err(SurfaceError::Renderer(
                RendererError::InvalidTextureExtent { .. }
            ))
        ));
        assert!(!surface.is_attached());
        assert_eq!(surface.dimensions(), (16, 12));
        assert_eq!(factory.dimensions(), (16, 12));

        assert_eq!(
            surface.reattach(&mut factory, 10, 6).unwrap(),
            SurfaceDisposition::Recreated
        );
        assert!(surface.is_attached());
        assert_eq!(surface.dimensions(), (10, 6));
        assert_eq!(factory.dimensions(), (10, 6));
    }

    #[test]
    fn null_drawable_is_a_bounded_timeout_outcome() {
        let (factory, mut surface) =
            AppleSurface::attach_with_factory(2, 2, RenderMode::Msaa).unwrap();
        let frame = factory.begin_frame(0x0000_0000);

        let (disposition, _) =
            unsafe { surface.present(frame, std::ptr::null_mut(), None).unwrap() };

        assert_eq!(disposition, SurfaceDisposition::SkippedTimeout);
    }

    #[test]
    fn detached_surface_rejects_present_before_inspecting_the_drawable() {
        let (factory, mut surface) =
            AppleSurface::attach_with_factory(2, 2, RenderMode::Msaa).unwrap();
        surface.detach();
        let frame = factory.begin_frame(0x0000_0000);

        assert!(matches!(
            unsafe { surface.present(frame, std::ptr::null_mut(), None) },
            Err(SurfaceError::Unsupported("surface is not attached"))
        ));
    }

    #[test]
    fn recorded_device_failures_become_structured_surface_outcomes() {
        for (kind, expected) in [
            (
                WgpuExternalDeviceFailureKind::DeviceLost,
                SurfaceDisposition::DeviceLost,
            ),
            (
                WgpuExternalDeviceFailureKind::OutOfMemory,
                SurfaceDisposition::OutOfMemory,
            ),
        ] {
            let (factory, mut surface) =
                AppleSurface::attach_with_factory(2, 2, RenderMode::Msaa).unwrap();
            let frame = factory.begin_frame(0x0000_0000);
            surface
                .presenter
                .record_external_failure(kind, "injected device failure".to_owned());

            let (disposition, _) =
                unsafe { surface.present(frame, std::ptr::null_mut(), None).unwrap() };
            assert_eq!(disposition, expected);
        }
    }

    #[test]
    fn recorded_validation_error_is_returned_instead_of_panicking() {
        let (factory, mut surface) =
            AppleSurface::attach_with_factory(2, 2, RenderMode::Msaa).unwrap();
        let frame = factory.begin_frame(0x0000_0000);
        surface.presenter.record_external_failure(
            WgpuExternalDeviceFailureKind::Internal,
            "injected validation error".to_owned(),
        );

        assert!(matches!(
            unsafe { surface.present(frame, std::ptr::null_mut(), None) },
            Err(SurfaceError::Renderer(RendererError::Device(message)))
                if message == "injected validation error"
        ));
    }

    #[test]
    fn configured_cametal_layer_drawable_is_rendered_and_scheduled_for_presentation() {
        autoreleasepool(|_| {
            let (factory, mut surface) =
                AppleSurface::attach_with_factory(4, 3, RenderMode::Msaa).unwrap();
            let layer = configured_layer(&surface, 4, 3);
            let drawable = layer
                .nextDrawable()
                .expect("configured CAMetalLayer must vend a drawable");
            assert_eq!(drawable.texture().width(), 4);
            assert_eq!(drawable.texture().height(), 3);
            assert_eq!(drawable.texture().pixelFormat(), MTLPixelFormat::BGRA8Unorm);
            let drawable_pointer = Retained::as_ptr(&drawable).cast_mut().cast::<c_void>();
            let completed = Arc::new(AtomicBool::new(false));
            let completed_for_callback = Arc::clone(&completed);

            let frame = factory.begin_frame(0xff11_2233);
            let (disposition, _) = unsafe {
                surface
                    .present(
                        frame,
                        drawable_pointer,
                        Some(ApplePresentationCompletion::new(move || {
                            completed_for_callback.store(true, Ordering::Release);
                        })),
                    )
                    .unwrap()
            };
            wait_for_metal_queue(&surface);

            assert_eq!(disposition, SurfaceDisposition::Presented);
            assert!(completed.load(Ordering::Acquire));
        });
    }

    #[test]
    fn completion_fires_when_presentation_is_skipped_before_submission() {
        let (factory, mut surface) =
            AppleSurface::attach_with_factory(2, 2, RenderMode::Msaa).unwrap();
        let completed = Arc::new(AtomicBool::new(false));
        let completed_for_callback = Arc::clone(&completed);
        let frame = factory.begin_frame(0x0000_0000);

        let (disposition, _) = unsafe {
            surface
                .present(
                    frame,
                    std::ptr::null_mut(),
                    Some(ApplePresentationCompletion::new(move || {
                        completed_for_callback.store(true, Ordering::Release);
                    })),
                )
                .unwrap()
        };

        assert_eq!(disposition, SurfaceDisposition::SkippedTimeout);
        assert!(completed.load(Ordering::Acquire));
    }

    #[test]
    fn metal_completion_errors_map_to_structured_device_health() {
        assert_eq!(
            metal_failure_kind(Some(MTLCommandBufferError::OutOfMemory.0 as isize)),
            WgpuExternalDeviceFailureKind::OutOfMemory
        );
        assert_eq!(
            metal_failure_kind(Some(MTLCommandBufferError::DeviceRemoved.0 as isize)),
            WgpuExternalDeviceFailureKind::DeviceLost
        );
        assert_eq!(
            metal_failure_kind(Some(MTLCommandBufferError::Internal.0 as isize)),
            WgpuExternalDeviceFailureKind::Internal
        );
    }
}
