import Foundation

private struct E2EArtifact: Decodable {
  let publicApiKey: String?
  let ingestUrl: String?
  let triggerEvent: String?
}

struct E2EConfiguration: Equatable {
  static let apiKeyEnvKey = "NUXIE_E2E_API_KEY"
  static let ingestUrlEnvKey = "NUXIE_E2E_INGEST_URL"
  static let triggerEventEnvKey = "NUXIE_E2E_TRIGGER_EVENT"
  static let artifactEnvKey = "NUXIE_E2E_ARTIFACT_PATH"

  static let defaultApiKey = "pk_test_placeholder"
  static let defaultIngestUrlString = "http://localhost:8084"
  static let defaultTriggerEvent = "nuxie_e2e_trigger"

  let apiKey: String
  let ingestUrl: URL
  let triggerEvent: String

  var ingestUrlString: String {
    ingestUrl.absoluteString
  }

  static func fromProcessInfo(_ processInfo: ProcessInfo = .processInfo) -> E2EConfiguration {
    fromEnvironment(environment: processInfo.environment)
  }

  static func fromEnvironment(
    environment: [String: String],
    fileLoader: (String) -> Data? = { path in
      try? Data(contentsOf: URL(fileURLWithPath: path))
    }
  ) -> E2EConfiguration {
    let apiKeyOverride = nonEmpty(environment[apiKeyEnvKey])
    let ingestUrlOverride = nonEmpty(environment[ingestUrlEnvKey])
    let triggerEventOverride = nonEmpty(environment[triggerEventEnvKey])

    var artifact: E2EArtifact?
    if let artifactPath = nonEmpty(environment[artifactEnvKey]),
       let data = fileLoader(resolveArtifactFilePath(artifactPath)) {
      artifact = try? JSONDecoder().decode(E2EArtifact.self, from: data)
    }

    let apiKey = apiKeyOverride
      ?? nonEmpty(artifact?.publicApiKey)
      ?? defaultApiKey

    let ingestUrlString = ingestUrlOverride
      ?? nonEmpty(artifact?.ingestUrl)
      ?? defaultIngestUrlString

    let triggerEvent = triggerEventOverride
      ?? nonEmpty(artifact?.triggerEvent)
      ?? defaultTriggerEvent

    let ingestUrl = URL(string: ingestUrlString)
      ?? URL(string: defaultIngestUrlString)!

    return E2EConfiguration(
      apiKey: apiKey,
      ingestUrl: ingestUrl,
      triggerEvent: triggerEvent
    )
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
      return nil
    }
    return trimmed
  }

  private static func resolveArtifactFilePath(_ rawPath: String) -> String {
    let artifactURL = URL(fileURLWithPath: rawPath)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: rawPath, isDirectory: &isDirectory),
       isDirectory.boolValue {
      return artifactURL.appendingPathComponent("runtime/launch-config.json").path
    }

    if artifactURL.pathExtension.isEmpty {
      return artifactURL.appendingPathComponent("runtime/launch-config.json").path
    }

    return rawPath
  }
}
