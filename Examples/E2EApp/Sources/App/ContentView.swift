import SwiftUI
import Nuxie

private enum SetupState: Equatable {
  case idle
  case ready
  case error(String)
}

struct ContentView: View {
  let configuration: E2EConfiguration

  @State private var setupState: SetupState = .idle
  @State private var errorMessage: String?

  var body: some View {
    NavigationView {
      Form {
        Section("E2E Configuration") {
          labeledValue("API Key", configuration.apiKey, id: "config-api-key")
          labeledValue("Ingest URL", configuration.ingestUrlString, id: "config-ingest-url")
          labeledValue("Flow ID", configuration.flowId, id: "config-flow-id")
        }

        Section("SDK") {
          Button("Setup SDK") {
            setupSdk()
          }
          .accessibilityIdentifier("setup-button")

          Button("Show Flow") {
            showFlow()
          }
          .accessibilityIdentifier("show-flow-button")
          .disabled(!isReady)

          Text(setupStateLabel)
            .accessibilityIdentifier("setup-state")
        }

        if let errorMessage {
          Section("Errors") {
            Text(errorMessage)
              .foregroundStyle(.red)
              .accessibilityIdentifier("error-label")
          }
        }
      }
      .navigationTitle("Nuxie E2E")
    }
    .navigationViewStyle(.stack)
  }

  private var isReady: Bool {
    if case .ready = setupState {
      return true
    }
    return false
  }

  private var setupStateLabel: String {
    switch setupState {
    case .idle:
      return "idle"
    case .ready:
      return "ready"
    case .error(let message):
      return "error: \(message)"
    }
  }

  @ViewBuilder
  private func labeledValue(_ label: String, _ value: String, id: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.body)
        .textSelection(.enabled)
        .accessibilityIdentifier(id)
    }
    .padding(.vertical, 4)
  }

  private func setupSdk() {
    errorMessage = nil

    if NuxieSDK.shared.configuration != nil {
      setupState = .ready
      return
    }

    let sdkConfiguration = NuxieConfiguration(apiKey: configuration.apiKey)
    sdkConfiguration.apiEndpoint = configuration.ingestUrl
    sdkConfiguration.logLevel = .debug

    do {
      try NuxieSDK.shared.setup(with: sdkConfiguration)
      setupState = .ready
    } catch {
      setupState = .error(error.localizedDescription)
      errorMessage = error.localizedDescription
    }
  }

  private func showFlow() {
    errorMessage = nil

    guard isReady else {
      let message = "SDK not setup"
      setupState = .error(message)
      errorMessage = message
      return
    }

    Task {
      do {
        try await NuxieSDK.shared.showFlow(with: configuration.flowId)
      } catch {
        await MainActor.run {
          errorMessage = error.localizedDescription
          setupState = .error(error.localizedDescription)
        }
      }
    }
  }
}
