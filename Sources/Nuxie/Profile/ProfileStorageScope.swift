import CryptoKit
import Foundation

/// Opaque disk-cache namespace for one configured API credential and SDK
/// endpoint environment. A cache written for another app cannot become this
/// setup's first profile-delivery authority.
struct ProfileStorageScope: Equatable, Hashable, Sendable {
    private static let domain = "nuxie.profile-storage.v2\u{0}"

    let cacheSubdirectory: String
    let authorityBindingFilename: String

    init(apiKey: String, environment: Environment) {
        let digest = SHA256.hash(data: Data(
            (Self.domain + environment.rawValue + "\u{0}" + apiKey).utf8
        ))
        .map { String(format: "%02x", $0) }
        .joined()
        cacheSubdirectory = "profiles-v2-\(digest)"
        authorityBindingFilename = "\(digest).json"
    }
}
