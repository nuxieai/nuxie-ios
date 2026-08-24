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

        switch action.payload?["format"] {
        case .string(let format): exportDocument(format: format)
        default: break
        }
    }
}
```

`AppAction.experience` identifies the exact experience version and journey
that requested the action. Payload references are resolved before delivery.
The public payload vocabulary contains JSON-safe string, integer, finite
double, and Boolean scalars. Resolved arrays and objects are preserved as
compact JSON strings, while null and non-finite numeric values are omitted.

The callback runs on the main actor. Nuxie also captures the hidden
`$app_action_requested` rider for its own observability. Signed-route replay
protection prevents an already claimed App Action from being delivered twice.
