import Foundation

// Matches SwiftPM's resource bundle name for static consumers and framework
// consumers without making either depend on their current working directory.
private final class NuxieBazelResourceToken {}

extension Bundle {
    static let module: Bundle = {
        let owner = Bundle(for: NuxieBazelResourceToken.self)
        let roots = [owner.resourceURL, Bundle.main.resourceURL, owner.bundleURL.deletingLastPathComponent()]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent("Nuxie_Nuxie.bundle")) {
                return bundle
            }
        }
        preconditionFailure("Nuxie_Nuxie.bundle is missing from the SDK consumer")
    }()
}
