import Foundation

#if canImport(UIKit)
import UIKit

/// Colors for the native shell, derived from the *authored* background rather
/// than the trait environment.
///
/// The controller forces `overrideUserInterfaceStyle` from the experience's
/// color-scheme mode, so semantic colors like `.label` resolve against that
/// mode and not against the background a descriptor actually authored. A
/// light-mode `.label` on an authored near-black background is effectively
/// invisible, which is how the recovery affordances used to render. Deriving
/// from measured background luminance keeps shell chrome legible over light,
/// dark, and arbitrary authored colors.
struct ExperienceShellPalette: Equatable {
    /// True when chrome should render light-on-dark.
    let prefersLightContent: Bool

    /// Titles and control glyphs.
    var primary: UIColor {
        prefersLightContent
            ? UIColor(white: 1, alpha: 0.95)
            : UIColor(white: 0, alpha: 0.9)
    }

    /// Explanatory copy.
    var secondary: UIColor {
        prefersLightContent
            ? UIColor(white: 1, alpha: 0.62)
            : UIColor(white: 0, alpha: 0.56)
    }

    /// Tint for the recovery glyph.
    ///
    /// The shell has no brand input from the descriptor, so this is the system
    /// accent rather than anything authored: the recovery state is SDK chrome
    /// interrupting the experience, not part of it, and reading as platform
    /// chrome is the honest signal. The two values are iOS's own light and dark
    /// blues, picked explicitly because the controller forces
    /// `overrideUserInterfaceStyle` and cannot rely on a dynamic color
    /// resolving the way the authored background needs.
    var accentTint: UIColor {
        prefersLightContent
            ? UIColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
            : UIColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)
    }

    /// Label on the glass action.
    var accentLabel: UIColor {
        prefersLightContent
            ? UIColor(white: 1, alpha: 0.95)
            : UIColor(white: 0.06, alpha: 1)
    }

    /// Tint applied under glass so a control keeps contrast on backgrounds the
    /// blur alone cannot separate from.
    var glassTint: UIColor {
        prefersLightContent
            ? UIColor(white: 1, alpha: 0.14)
            : UIColor(white: 0, alpha: 0.06)
    }

    /// Material for floating controls. Chosen to sit opposite the background
    /// so the control reads as raised rather than dissolving into it.
    var blurStyle: UIBlurEffect.Style {
        prefersLightContent ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight
    }

    /// Color and amount mixed into the authored background for the shimmer
    /// band.
    ///
    /// A light background has to darken; blending it further toward white,
    /// as a fixed white highlight does, moves it a few values it has left and
    /// reads as nothing at all. The fractions are set so the band clears a
    /// visible margin on both polarities without turning the wait into a
    /// flashing surface.
    var shimmerHighlight: (color: UIColor, fraction: CGFloat) {
        prefersLightContent ? (.white, 0.16) : (.black, 0.09)
    }

    /// Derives a palette from the first background color that is opaque enough
    /// to judge. Transparent authored backgrounds carry no information about
    /// what will sit behind them, so they fall back to light-on-dark, which is
    /// the safer default over the unknown content of a host app.
    ///
    /// Polarity is chosen by measuring both options rather than by splitting
    /// luminance at its midpoint. Contrast is not linear in luminance: the
    /// ratios against white and black are equal only near luminance 0.179, so
    /// a midpoint cutoff picks light content across a wide band of ordinary
    /// mid-tone colors where dark content is far more readable. A #AAAAAA
    /// background gives white 2.3:1 and black 9.0:1.
    init(backgroundCandidates: [UIColor?]) {
        let opaque = backgroundCandidates
            .compactMap { $0 }
            .first { $0.nuxieAlpha >= 0.5 }
        guard let opaque else {
            prefersLightContent = true
            return
        }
        prefersLightContent = opaque.nuxieContrastWithWhite >= opaque.nuxieContrastWithBlack
    }

    init(prefersLightContent: Bool) {
        self.prefersLightContent = prefersLightContent
    }
}

extension UIColor {
    var nuxieAlpha: CGFloat {
        var alpha: CGFloat = 0
        guard getRed(nil, green: nil, blue: nil, alpha: &alpha) else {
            var white: CGFloat = 0
            guard getWhite(&white, alpha: &alpha) else { return 1 }
            return alpha
        }
        return alpha
    }

    /// WCAG relative luminance, used only to decide light-on-dark vs
    /// dark-on-light. Colors that cannot be resolved into a component space
    /// report mid-grey so the caller falls back deliberately.
    var nuxieRelativeLuminance: CGFloat {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if !getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            guard getWhite(&white, alpha: &alpha) else { return 0.5 }
            red = white
            green = white
            blue = white
        }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG contrast ratio of pure white against this color.
    var nuxieContrastWithWhite: CGFloat {
        1.05 / (nuxieRelativeLuminance + 0.05)
    }

    /// WCAG contrast ratio of pure black against this color.
    var nuxieContrastWithBlack: CGFloat {
        (nuxieRelativeLuminance + 0.05) / 0.05
    }

    func nuxieBlended(with other: UIColor, fraction: CGFloat) -> UIColor {
        let amount = min(max(fraction, 0), 1)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var otherRed: CGFloat = 0
        var otherGreen: CGFloat = 0
        var otherBlue: CGFloat = 0
        var otherAlpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha),
              other.getRed(
                &otherRed,
                green: &otherGreen,
                blue: &otherBlue,
                alpha: &otherAlpha
              ) else {
            return self
        }
        return UIColor(
            red: red + (otherRed - red) * amount,
            green: green + (otherGreen - green) * amount,
            blue: blue + (otherBlue - blue) * amount,
            alpha: alpha + (otherAlpha - alpha) * amount
        )
    }

    convenience init?(nuxieRGBAHex value: String) {
        guard value.count == 9, value.first == "#",
              let rgba = UInt32(value.dropFirst(), radix: 16) else {
            return nil
        }
        self.init(
            red: CGFloat((rgba >> 24) & 0xff) / 255,
            green: CGFloat((rgba >> 16) & 0xff) / 255,
            blue: CGFloat((rgba >> 8) & 0xff) / 255,
            alpha: CGFloat(rgba & 0xff) / 255
        )
    }
}
#endif
