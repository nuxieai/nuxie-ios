# Experience accessibility qualification

The runtime host has a dedicated launch mode for the signed accessibility
Journey:

```text
--nuxie-accessibility-qualification
```

Build `NuxieExperienceRuntimeHostApp`, launch with this argument, and choose
**Start Experience**. The host runs the ordinary SDK, profile authentication,
artifact acquisition, presentation, native editors, and durable Journey actions.
Its isolated URL session serves the committed `rendered-semantic-roles` fixture
locally and rejects other requests. The signed envelope and artifact bytes remain
unchanged. Profile responses carry the normal authority headers and an ETag
computed from the profile bytes.

The host explicitly enables the candidate capability through the Testing SPI in
the development environment. The same option cannot admit the capability in
staging or production. Normal SDK defaults remain closed until release
qualification is complete.

Each start retains a separate SDK storage directory under
`Documents/accessibility-qualification/<run-id>`. Use the ordinary durable
Journey journal to verify action effects and distinguish accepted actions from
duplicate callbacks. Do not infer successful actions from a method returning
true or from a spoken acknowledgement alone. Use synthetic input data and redact
input values when sharing evidence.

This mode has a visible launch interface and does not install the ordinary
fixture browser's hidden status labels. Presentation diagnostics are disabled.
After dismissal, check that focus returns to a usable host control.

## Automated preparation

The hosted `SignedSemanticJourneyTests` exercise authentic signed fixtures,
state mapping, native secure input, durable effects, and development-only
candidate admission. The installed-app UI test
`testAccessibilityQualificationHostRunsSignedJourneyWithoutDiagnosticElements`
checks SDK startup, native accessibility exposure, and absence of diagnostic
probe elements. These are prerequisites, not VoiceOver interaction evidence.

## Physical VoiceOver evidence

Install the qualified build on the paired iPhone and use actual VoiceOver.
Record SDK commit, runtime artifact identity, fixture provenance and hash,
device/OS/VoiceOver version, procedure, observed result, and evidence location.
For this role fixture, check forward/backward traversal, heading navigation,
checked/selected and mixed/required speech, slider value and adjustments, secure
editing, action effects, and dismissal/return. Capture the relevant durable
journal for action counts. Repeated labels must remain distinct occurrences.

The role fixture does not cover the full acceptance corpus. Scrolling, modal
isolation, validation announcements, meaningful media, alternative inputs,
transition/lifecycle cases, and the other agreed journeys require their own
signed-fixture evidence before capability admission. Font and scaling work is
owned separately and is not a qualification gate in this program.
