//! Apple drawable-presentation adapter.
//!
//! This package owns drawable validation and wrapping, surface lifecycle,
//! presentation scheduling/completion policy, and trusted Apple image
//! admission. The renderer remains behind an opaque Metal-capable seam.

#[cfg(any(target_os = "ios", target_os = "macos"))]
mod apple;

#[cfg(any(target_os = "ios", target_os = "macos"))]
pub use apple::{ApplePresentationCompletion, AppleSurface, SurfaceDisposition, SurfaceError};

/// Trusted-artifact image admission for Apple product imports.
pub struct AppleImageAdmission;

impl AppleImageAdmission {
    /// Fully decodes a supported image and enforces the Apple-safe 8,192-pixel
    /// dimension and 64 MiB decoded-RGBA ceilings without retaining pixels.
    pub fn validate_image_bytes(data: &[u8]) -> Result<(), nuxie_render_api::ImageDecodeError> {
        // Apple intentionally adds no weaker or broader admission policy than
        // the portable codec baseline supplied by the pinned engine.
        nuxie_image_codec::validate_encoded_image(data)
            .map(|_| ())
            .ok_or(nuxie_render_api::ImageDecodeError)
    }
}

#[cfg(test)]
mod image_admission_tests {
    use super::AppleImageAdmission;

    #[test]
    fn accepts_a_fully_decodable_image() {
        let mut encoded = Vec::new();
        let mut encoder = png::Encoder::new(&mut encoded, 1, 1);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder
            .write_header()
            .unwrap()
            .write_image_data(&[10, 20, 30, 255])
            .unwrap();

        assert!(AppleImageAdmission::validate_image_bytes(&encoded).is_ok());
    }

    #[test]
    fn rejects_images_over_the_decoded_byte_ceiling_during_preflight() {
        const PIXEL_BOMB_DIMENSION: u32 = 4_097;
        let mut encoded = Vec::new();
        let writer = png::Encoder::new(&mut encoded, PIXEL_BOMB_DIMENSION, PIXEL_BOMB_DIMENSION)
            .write_header()
            .expect("PNG header encodes");
        drop(writer);

        assert!(AppleImageAdmission::validate_image_bytes(&encoded).is_err());
    }
}
