import CryptoKit
import Foundation

enum SHA256Provider {
    static func hexDigest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
