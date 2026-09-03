import XCTest
@testable import NuxieE2EApp

final class E2EConfigurationTests: XCTestCase {
  func testEnvironmentOverridesArtifact() {
    let environment: [String: String] = [
      E2EConfiguration.apiKeyEnvKey: "pk_env",
      E2EConfiguration.ingestUrlEnvKey: "http://env.example",
      E2EConfiguration.triggerEventEnvKey: "event_env",
      E2EConfiguration.artifactEnvKey: "/tmp/artifact.json",
    ]

    let artifactJson = """
    {
      "publicApiKey": "pk_artifact",
      "ingestUrl": "http://artifact.example",
      "triggerEvent": "event_artifact"
    }
    """

    let configuration = E2EConfiguration.fromEnvironment(
      environment: environment,
      fileLoader: makeLoader(json: artifactJson)
    )

    XCTAssertEqual(configuration.apiKey, "pk_env")
    XCTAssertEqual(configuration.ingestUrlString, "http://env.example")
    XCTAssertEqual(configuration.triggerEvent, "event_env")
  }

  func testArtifactFallbackWhenEnvironmentMissing() {
    let environment: [String: String] = [
      E2EConfiguration.artifactEnvKey: "/tmp/artifact.json",
    ]

    let artifactJson = """
    {
      "publicApiKey": "pk_artifact",
      "ingestUrl": "http://artifact.example",
      "triggerEvent": "event_artifact"
    }
    """

    let configuration = E2EConfiguration.fromEnvironment(
      environment: environment,
      fileLoader: makeLoader(json: artifactJson)
    )

    XCTAssertEqual(configuration.apiKey, "pk_artifact")
    XCTAssertEqual(configuration.ingestUrlString, "http://artifact.example")
    XCTAssertEqual(configuration.triggerEvent, "event_artifact")
  }

  func testDefaultsWhenNoEnvironmentOrArtifact() {
    let configuration = E2EConfiguration.fromEnvironment(environment: [:]) { _ in nil }

    XCTAssertEqual(configuration.apiKey, E2EConfiguration.defaultApiKey)
    XCTAssertEqual(configuration.ingestUrlString, E2EConfiguration.defaultIngestUrlString)
    XCTAssertEqual(configuration.triggerEvent, E2EConfiguration.defaultTriggerEvent)
  }

  func testDirectoryArtifactPathResolvesLaunchConfig() {
    let environment: [String: String] = [
      E2EConfiguration.artifactEnvKey: "/tmp/scenario-release"
    ]

    let artifactJson = """
    {
      "publicApiKey": "pk_artifact_dir",
      "ingestUrl": "http://artifact-dir.example",
      "triggerEvent": "event_artifact_dir"
    }
    """

    let configuration = E2EConfiguration.fromEnvironment(
      environment: environment,
      fileLoader: { path in
        XCTAssertEqual(path, "/tmp/scenario-release/runtime/launch-config.json")
        return artifactJson.data(using: .utf8)
      }
    )

    XCTAssertEqual(configuration.apiKey, "pk_artifact_dir")
    XCTAssertEqual(configuration.ingestUrlString, "http://artifact-dir.example")
    XCTAssertEqual(configuration.triggerEvent, "event_artifact_dir")
  }

  private func makeLoader(json: String) -> (String) -> Data? {
    { _ in json.data(using: .utf8) }
  }
}
