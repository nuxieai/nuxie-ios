import SwiftUI

/// A deliberately empty host that gives StoreKitTest an application process.
/// The production SDK is exercised by the hosted test bundle, not this app.
@main
struct NuxieStoreKitTestHost: App {
    var body: some Scene {
        WindowGroup {
            Color.clear
        }
    }
}
