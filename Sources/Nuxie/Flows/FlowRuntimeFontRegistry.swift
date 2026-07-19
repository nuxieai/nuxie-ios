import Foundation
#if canImport(CoreText)
import CoreText
#endif
#if canImport(UIKit)
import UIKit
#endif

struct FlowRuntimeRegisteredFontCatalog {
    struct Identity: Hashable {
        let riveUniqueName: String
        let contentSHA256: String
    }

    private(set) var postScriptNamesByIdentity: [Identity: String] = [:]

    mutating func record(
        riveUniqueName: String,
        contentSHA256: String,
        postScriptName: String
    ) {
        postScriptNamesByIdentity[
            Identity(
                riveUniqueName: riveUniqueName,
                contentSHA256: contentSHA256.lowercased()
            )
        ] = postScriptName
    }

    func postScriptName(
        forRiveUniqueName riveUniqueName: String,
        contentSHA256: String
    ) -> String? {
        postScriptNamesByIdentity[
            Identity(
                riveUniqueName: riveUniqueName,
                contentSHA256: contentSHA256.lowercased()
            )
        ]
    }
}

enum FlowRuntimeFontRegistry {
    private static let lock = NSLock()
    private static var catalog = FlowRuntimeRegisteredFontCatalog()
    #if canImport(CoreText)
    private static var graphicsFontsByIdentity: [
        FlowRuntimeRegisteredFontCatalog.Identity: CGFont
    ] = [:]
    #endif

    @discardableResult
    static func registerFont(riveUniqueName: String, data: Data) -> String? {
        #if canImport(CoreText)
        let contentSHA256 = FlowArtifactStore.sha256Hex(data)
        let identity = FlowRuntimeRegisteredFontCatalog.Identity(
            riveUniqueName: riveUniqueName,
            contentSHA256: contentSHA256
        )
        lock.lock()
        if let postScriptName = catalog.postScriptName(
            forRiveUniqueName: riveUniqueName,
            contentSHA256: contentSHA256
        ), graphicsFontsByIdentity[identity] != nil {
            lock.unlock()
            return postScriptName
        }
        lock.unlock()

        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider),
              let postScriptName = font.postScriptName as String? else {
            return nil
        }

        var registerError: Unmanaged<CFError>?
        let registeredGlobally = CTFontManagerRegisterGraphicsFont(font, &registerError)
        if !registeredGlobally {
            guard let error = registerError?.takeRetainedValue() else {
                LogWarning(
                    "FlowRuntimeFontRegistry: registration failed without a CoreText error "
                        + "for \(riveUniqueName)"
                )
                return nil
            }
            guard isDuplicateFontRegistrationError(error) else {
                LogWarning(
                    "FlowRuntimeFontRegistry: failed to register font "
                        + "\(riveUniqueName): \(CFErrorCopyDescription(error) as String)"
                )
                return nil
            }
            // CoreText's process-wide registry cannot replace an existing
            // PostScript name. Keep the exact content-backed CGFont so two
            // live artifact revisions can still use their own bytes.
            LogDebug(
                "FlowRuntimeFontRegistry: retained content-backed duplicate "
                    + "font \(riveUniqueName)"
            )
        }

        lock.lock()
        catalog.record(
            riveUniqueName: riveUniqueName,
            contentSHA256: contentSHA256,
            postScriptName: postScriptName
        )
        graphicsFontsByIdentity[identity] = font
        lock.unlock()
        return postScriptName
        #else
        return nil
        #endif
    }

    #if canImport(UIKit) && canImport(CoreText)
    static func font(
        forRiveUniqueName riveUniqueName: String,
        contentSHA256: String,
        size: CGFloat
    ) -> UIFont? {
        let identity = FlowRuntimeRegisteredFontCatalog.Identity(
            riveUniqueName: riveUniqueName,
            contentSHA256: contentSHA256.lowercased()
        )
        lock.lock()
        let graphicsFont = graphicsFontsByIdentity[identity]
        lock.unlock()
        guard let graphicsFont else { return nil }

        return CTFontCreateWithGraphicsFont(
            graphicsFont,
            max(1, size),
            nil,
            nil
        ) as UIFont
    }
    #endif

    #if canImport(CoreText)
    private static func isDuplicateFontRegistrationError(_ error: CFError) -> Bool {
        [105, 305].contains(CFErrorGetCode(error))
    }
    #endif
}
