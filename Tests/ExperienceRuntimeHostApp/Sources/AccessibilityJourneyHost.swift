import CryptoKit
import Foundation
@_spi(Testing) import Nuxie
import UIKit

/// Runs the ordinary SDK and durable Journey pipeline with locally delivered,
/// production-generated signed artifacts. Assistive actions are never simulated.
final class AccessibilityJourneyHostViewController: UIViewController {
    private let status = UILabel()
    private let start = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Accessibility qualification"
        view.backgroundColor = .systemBackground
        status.text = "Start the signed Experience, then use VoiceOver."
        status.numberOfLines = 0
        start.setTitle("Start Experience", for: .normal)
        start.accessibilityIdentifier = "start-accessibility-journey"
        start.addTarget(self, action: #selector(startJourney), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [status, start])
        stack.axis = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
        ])
    }

    @objc private func startJourney() {
        start.isEnabled = false
        Task { @MainActor in
            await NuxieSDK.shared.shutdown()
            do {
                // Validate the fixture before setting up a SDK run. Each run gets
                // its own journal so a completed prior run cannot suppress entry.
                _ = try AccessibilityFixtureProtocol.fixture.get()
                let sessionConfiguration = URLSessionConfiguration.ephemeral
                sessionConfiguration.protocolClasses = [AccessibilityFixtureProtocol.self]
                let configuration = NuxieConfiguration(apiKey: "accessibility-qualification")
                configuration.environment = .development
                configuration.testingOverrides.apiEndpoint = URL(string: "https://semantic.sdk-fixtures.nuxie.test")!
                configuration.testingOverrides.urlSession = URLSession(configuration: sessionConfiguration)
                configuration.testingOverrides.qualifyExperienceAccessibility = true
                configuration.testingOverrides.customStoragePath = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                )[0].appendingPathComponent("accessibility-qualification/\(UUID().uuidString)", isDirectory: true)
                configuration.testingOverrides.presentationDiagnosticsEnabled = false
                try NuxieSDK.shared.setup(with: configuration)
                status.text = "SDK started; waiting for the signed Experience. The journal is retained in Documents/accessibility-qualification."
            } catch {
                status.text = "Unable to start Experience: \(error.localizedDescription)"
            }
            start.isEnabled = true
        }
    }
}

private struct AccessibilityFixture {
    let root: URL
    let profile: Data
    let appID: String
    let environment: String
    let contentTypes: [String: String]

    init() throws {
        guard let resource = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        root = resource.appendingPathComponent("rendered-semantic-roles", isDirectory: true)
        let data = try Data(contentsOf: root.appendingPathComponent("release-entry.json"))
        guard let entry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let locator = entry["locator"] as? [String: Any],
              let envelope = entry["envelope"] as? [String: Any],
              let appID = locator["appId"] as? String,
              let environment = locator["environment"] as? String,
              let experienceID = locator["experienceId"] as? String,
              let versionID = locator["experienceVersionId"] as? String,
              let legID = locator["legId"] as? String,
              let digest = envelope["descriptorSha256"] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.appID = appID
        self.environment = environment
        guard let encoded = envelope["descriptorBytesBase64"] as? String,
              let descriptorBytes = Data(base64Encoded: encoded),
              let descriptor = try JSONSerialization.jsonObject(with: descriptorBytes) as? [String: Any],
              let render = descriptor["render"] as? [String: Any],
              let riv = render["nux"] as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let references = [riv] + (render["assets"] as? [[String: Any]] ?? [])
            + (descriptor["screenBehaviors"] as? [[String: Any]] ?? []).compactMap {
                ($0["script"] as? [String: Any])?["artifact"] as? [String: Any]
            }
        var contentTypes = [String: String]()
        for reference in references {
            guard let key = reference["key"] as? String,
                  let type = reference["contentType"] as? String else {
                throw CocoaError(.fileReadCorruptFile)
            }
            contentTypes[key] = type
        }
        self.contentTypes = contentTypes
        // The envelope is copied intact. Normal SDK authentication and artifact
        // hash verification remain responsible for accepting the signed bytes.
        profile = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": "nuxie.journey-plane-profile.v1", "status": "ok",
            "delivery": [
                "renderBaseUrl": "https://semantic.sdk-fixtures.nuxie.test/",
                "assetBaseUrl": "https://semantic.sdk-fixtures.nuxie.test/",
            ],
            "features": [],
            "facts": ["properties": [:], "memberships": [:], "assignments": [:]],
            "releases": [entry],
            "armedLegs": [[
                "reference": ["experienceId": experienceID, "versionId": versionID,
                              "legId": legID, "descriptorSha256": digest],
                "binding": ["type": "new"],
                "entryCondition": ["type": "app_foregrounded"],
                "context": ["event": [:], "responses": [:]],
            ]],
        ])
    }
}

/// This session never performs network requests; all unrecognized paths fail.
private final class AccessibilityFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let fixture: Result<AccessibilityFixture, Error> = Result { try AccessibilityFixture() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let fixture = try Self.fixture.get()
            guard let url = request.url, url.host == "semantic.sdk-fixtures.nuxie.test" else {
                throw URLError(.unsupportedURL)
            }
            let bytes: Data
            var headers = [String: String]()
            if url.path == "/profile" {
                bytes = fixture.profile
                headers = ["Content-Type": "application/json", "Nuxie-App-Id": fixture.appID,
                           "Nuxie-App-Environment": fixture.environment,
                           "ETag": "\"" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + "\""]
            } else {
                let key = String(url.path.dropFirst())
                let file = fixture.root.appendingPathComponent(key).standardizedFileURL
                guard file.path.hasPrefix(fixture.root.standardizedFileURL.path + "/"),
                      let contentType = fixture.contentTypes[key] else {
                    throw URLError(.resourceUnavailable)
                }
                bytes = try Data(contentsOf: file)
                headers["Content-Type"] = contentType
            }
            headers["Content-Length"] = String(bytes.count)
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers) else {
                throw URLError(.badServerResponse)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: bytes)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
