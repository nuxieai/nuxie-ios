# Run App Action

A Run App Action step lets an experience ask the host application to perform
a named action without embedding app-specific behavior in the experience
runtime. The published step uses the `app_action` discriminator:

```json
{
  "type": "app_action",
  "nodeId": "export-step",
  "name": "export_finished",
  "payload": {
    "format": { "type": "String", "value": "pdf" },
    "documentId": { "type": "Event.Field", "key": "document_id" }
  }
}
```

Receive the fully resolved request through `NuxieDelegate`:

```swift
@MainActor
final class ExperienceActions: NuxieDelegate {
    func nuxie(_ sdk: NuxieSDK, didRequestAppAction action: AppAction) {
        guard action.name == "export_finished" else { return }

        let payload = action.payload?.analyticsDictionary ?? [:]
        exportDocument(payload)
    }
}
```

`AppAction.experience` identifies the exact experience version and journey
that requested the action. Payload references are resolved before delivery.
The public payload vocabulary is scalar-only; resolved arrays and objects are
preserved as compact JSON strings, while null values are omitted.

The callback runs on the main actor. Nuxie then captures the hidden
`$app_action_requested` rider for its own observability; that rider is not
also sent through `nuxieDidEmit(_:)`. Signed-route replay protection prevents
an already claimed App Action from being delivered twice.
