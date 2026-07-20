extension FlowRuntimeDiagnostic {
    func log() {
        let rendered = "\(code): \(message)"
        switch severity {
        case .debug:
            LogDebug(rendered)
        case .warning:
            LogWarning(rendered)
        case .fatal:
            LogError(rendered)
        }
    }
}
