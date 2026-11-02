import Foundation
@_spi(Testing) import Nuxie
import UIKit

/// Launch-to-first-frame benchmark over the ordinary SDK pipeline.
///
/// `--nuxie-launch-benchmark` configures the SDK as the host view loads, with
/// the signed parla-sheets fixture served locally, then triggers its Journey
/// twice: once at launch and once more after dismissing the first show. Record
/// it with Instruments' os_signpost instrument (subsystem `ai.nuxie.sdk`).
///
/// - `--nuxie-benchmark-reset` deletes the benchmark's storage first, giving a
///   cold first launch. Without it, the previous launch's profile and release
///   caches stay, giving a warm launch.
/// - `--nuxie-benchmark-latency-ms <n>` holds every fixture response, standing
///   in for a network round trip.
/// - `--nuxie-benchmark-trigger-delay-ms <n>` waits before the first trigger
///   (default 0: onboarding shown at launch).
final class LaunchBenchmarkHostViewController: UIViewController {
    private let status = UILabel()

    private static var storage: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("launch-benchmark", isDirectory: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        status.numberOfLines = 0
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        do {
            try configure()
            status.text = "Launch benchmark running"
        } catch {
            status.text = "Launch benchmark failed: \(error.localizedDescription)"
            return
        }
        Task { @MainActor in await run() }
    }

    private func configure() throws {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--nuxie-benchmark-reset") {
            try? FileManager.default.removeItem(at: Self.storage)
        }
        _ = try AccessibilityFixtureProtocol.fixture.get()
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [AccessibilityFixtureProtocol.self]
        let configuration = NuxieConfiguration(apiKey: "launch-benchmark")
        configuration.environment = .development
        configuration.testingOverrides.apiEndpoint = URL(string: "https://semantic.sdk-fixtures.nuxie.test")!
        configuration.testingOverrides.urlSession = URLSession(configuration: session)
        configuration.testingOverrides.customStoragePath = Self.storage
        if arguments.contains("--nuxie-benchmark-verbose") {
            configuration.logLevel = .debug
            configuration.redactSensitiveData = false
        }
        try NuxieSDK.shared.setup(with: configuration)
    }

    private func run() async {
        let delay = Self.milliseconds("--nuxie-benchmark-trigger-delay-ms") ?? 0
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
        NuxieSDK.shared.trigger("lesson_opened")
        guard await waitForPresentation(true) else { return finish("first show never presented") }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        NSLog("nuxie-launch-benchmark: dismissing first show")
        await NuxieSDK.shared.dismiss()
        NSLog("nuxie-launch-benchmark: dismiss returned")
        guard await waitForPresentation(false) else { return finish("first show never dismissed") }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        NSLog("nuxie-launch-benchmark: second trigger")
        NuxieSDK.shared.trigger("lesson_opened")
        guard await waitForPresentation(true) else { return finish("second show never presented") }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        finish("Launch benchmark complete")
    }

    private func finish(_ message: String) {
        status.text = message
        NSLog("nuxie-launch-benchmark: %@", message)
    }

    private func waitForPresentation(_ presented: Bool) async -> Bool {
        for _ in 0..<300 {
            // The SDK presents in its own alert-level window.
            let showing = view.window?.windowScene?.windows.contains {
                $0.windowLevel == .alert && !$0.isHidden
                    && $0.rootViewController?.presentedViewController != nil
            } ?? false
            if showing == presented {
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private static func milliseconds(_ name: String) -> Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name),
              arguments.indices.contains(index + 1) else { return nil }
        return Int(arguments[index + 1])
    }
}
