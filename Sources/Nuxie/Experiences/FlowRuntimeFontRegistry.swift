import CryptoKit
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
    private struct Entry {
        let postScriptName: String
        #if canImport(CoreText)
        let graphicsFont: CGFont
        let registeredGlobally: Bool
        #endif
        var retainCount: Int
    }

    private static let lock = NSLock()
    // nonisolated(unsafe): all access to `entries` is serialized through `lock`.
    private nonisolated(unsafe) static var entries: [FlowRuntimeRegisteredFontCatalog.Identity: Entry] = [:]

    /// Validates font bytes without mutating CoreText's process-wide registry.
    /// Import preparation uses this so a failed native import cannot leak a
    /// permanent registration.
    static func isValidFontData(_ data: Data) -> Bool {
        #if canImport(CoreText)
        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider),
              font.postScriptName != nil else {
            return false
        }
        return true
        #else
        return true
        #endif
    }

    @discardableResult
    static func registerFont(
        riveUniqueName: String,
        data: Data,
        in scope: FlowRuntimeFontScope
    ) -> String? {
        #if canImport(CoreText)
        let contentSHA256 = sha256Hex(data)
        let identity = FlowRuntimeRegisteredFontCatalog.Identity(
            riveUniqueName: riveUniqueName,
            contentSHA256: contentSHA256
        )

        guard let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider),
              let postScriptName = font.postScriptName as String? else {
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        guard !scope.isClosed else { return nil }
        if scope.identities.contains(identity), let entry = entries[identity] {
            return entry.postScriptName
        }
        if var entry = entries[identity] {
            entry.retainCount += 1
            entries[identity] = entry
            scope.identities.insert(identity)
            return entry.postScriptName
        }

        var registerError: Unmanaged<CFError>?
        let registeredGlobally = CTFontManagerRegisterGraphicsFont(font, &registerError)
        if !registeredGlobally {
            guard let error = registerError?.takeRetainedValue() else {
                NSLog(
                    "FlowRuntimeFontRegistry: registration failed without a CoreText "
                        + "error for %@",
                    riveUniqueName
                )
                return nil
            }
            guard isDuplicateFontRegistrationError(error) else {
                NSLog(
                    "FlowRuntimeFontRegistry: failed to register font %@: %@",
                    riveUniqueName,
                    CFErrorCopyDescription(error) as String
                )
                return nil
            }
            // CoreText's process-wide registry cannot replace an existing
            // PostScript name. Keep the exact content-backed CGFont so two
            // live artifact revisions can still use their own bytes.
            NSLog(
                "FlowRuntimeFontRegistry: retained content-backed duplicate font %@",
                riveUniqueName
            )
        }

        entries[identity] = Entry(
            postScriptName: postScriptName,
            graphicsFont: font,
            registeredGlobally: registeredGlobally,
            retainCount: 1
        )
        scope.identities.insert(identity)
        return postScriptName
        #else
        return scope.isClosed ? nil : ""
        #endif
    }

    static func releaseFonts(in scope: FlowRuntimeFontScope) {
        lock.lock()
        defer { lock.unlock() }
        guard !scope.isClosed else { return }
        scope.isClosed = true

        for identity in scope.identities {
            guard var entry = entries[identity] else { continue }
            entry.retainCount -= 1
            guard entry.retainCount == 0 else {
                entries[identity] = entry
                continue
            }
            entries.removeValue(forKey: identity)
            #if canImport(CoreText)
            guard entry.registeredGlobally else { continue }
            var unregisterError: Unmanaged<CFError>?
            if !CTFontManagerUnregisterGraphicsFont(
                entry.graphicsFont,
                &unregisterError
            ) {
                if let error = unregisterError?.takeRetainedValue() {
                    NSLog(
                        "FlowRuntimeFontRegistry: failed to unregister font %@: %@",
                        identity.riveUniqueName,
                        CFErrorCopyDescription(error) as String
                    )
                } else {
                    NSLog(
                        "FlowRuntimeFontRegistry: unregistration failed without a "
                            + "CoreText error for %@",
                        identity.riveUniqueName
                    )
                }
            }
            #endif
        }
        scope.identities.removeAll()
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
        let graphicsFont = entries[identity]?.graphicsFont
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

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Owns the CoreText registrations needed by one live runtime context.
/// Releasing the last scope for exact font content removes both the private
/// CGFont and any process-wide registration Nuxie created for it.
final class FlowRuntimeFontScope: @unchecked Sendable {
    fileprivate var identities = Set<FlowRuntimeRegisteredFontCatalog.Identity>()
    fileprivate var isClosed = false

    func close() {
        FlowRuntimeFontRegistry.releaseFonts(in: self)
    }

    deinit {
        close()
    }
}
