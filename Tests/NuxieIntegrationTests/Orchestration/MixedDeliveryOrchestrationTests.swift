import Foundation
import Nimble
import Quick
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class MixedDeliveryOrchestrationTests: AsyncSpec {
    override class func spec() {
        describe("mixed signed and legacy profile routing") {
            var storageURL: URL!
            var stack: OrchestrationStack!

            beforeEach {
                storageURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "nuxie-orch-mixed-delivery-\(UUID().uuidString)",
                    isDirectory: true
                )
                stack = try await OrchestrationStack.boot(
                    storageURL: storageURL,
                    api: MockNuxieApi(),
                    dateProvider: MockDateProvider(),
                    sleepProvider: MockSleepProvider(),
                    distinctId: "mixed-delivery-user"
                )
            }

            afterEach {
                await stack?.shutdownForCleanup()
                stack = nil
                if let storageURL {
                    try? FileManager.default.removeItem(at: storageURL)
                }
            }

            it("enrolls signed and legacy event routes while preserving non-event legacy lookup") {
                let signed = OrchestrationFixtures.experience(
                    id: "signed-event",
                    flowId: "signed-version",
                    eventName: "mixed-event",
                    reentry: .everyTime
                )
                let multiScreen = OrchestrationFixtures.experience(
                    id: "legacy-multiscreen",
                    flowId: "legacy-multiscreen-version",
                    eventName: "mixed-event",
                    reentry: .everyTime
                )
                let legacyAPI = Self.nonEventExperience(
                    id: "legacy-api",
                    versionId: "legacy-api-version"
                )
                let legacyWebhook = Self.nonEventExperience(
                    id: "legacy-webhook",
                    versionId: "legacy-webhook-version"
                )
                let experiences = [signed, legacyAPI, legacyWebhook, multiScreen]
                let journeys = [
                    try OrchestrationFixtures.exitFlow(
                        id: signed.versionId,
                        trigger: "mixed-event",
                        effect: "signed-effect"
                    ),
                    JourneyDocument.empty,
                    JourneyDocument.empty,
                    try OrchestrationFixtures.exitFlow(
                        id: multiScreen.versionId,
                        trigger: "mixed-event",
                        effect: "multiscreen-effect"
                    ),
                ]
                stack.registerExperiences(journeys, metadata: experiences)
                stack.experienceService.authenticatedReleaseReferences = [
                    ExperienceReference(
                        experienceId: signed.id,
                        versionId: signed.versionId
                    )
                ]
                await stack.api.setProfileResponse(ProfileResponse(
                    experiences: experiences.map(\.remote),
                    segments: [],
                    assetBaseUrl: "https://assets.nuxie.ai/",
                    releases: Self.releaseProfile(
                        experienceId: signed.id,
                        versionId: signed.versionId
                    )
                ))

                _ = try await stack.core.profile.refetchProfile(
                    distinctId: stack.distinctId
                )

                let effective = await stack.core.profile
                    .getEffectiveExperienceReferences(distinctId: stack.distinctId)
                let active = await stack.core.profile
                    .getActiveExperienceReferences(distinctId: stack.distinctId)
                expect(effective).to(equal(experiences.map {
                    ExperienceReference(experienceId: $0.id, versionId: $0.versionId)
                }))
                expect(active).to(equal(effective))

                await stack.trackAndDrain("mixed-event")
                await expect {
                    await stack.journeyStartCount(experienceId: signed.id)
                }.toEventually(equal(1), timeout: .seconds(5))
                await expect {
                    await stack.journeyStartCount(experienceId: multiScreen.id)
                }.toEventually(equal(1), timeout: .seconds(5))
                let apiStartCount = await stack.journeyStartCount(
                    experienceId: legacyAPI.id
                )
                let webhookStartCount = await stack.journeyStartCount(
                    experienceId: legacyWebhook.id
                )
                expect(apiStartCount).to(equal(0))
                expect(webhookStartCount).to(equal(0))
                await expect { await stack.eventCount("signed-effect") }
                    .toEventually(equal(1), timeout: .seconds(5))
                await expect { await stack.eventCount("multiscreen-effect") }
                    .toEventually(equal(1), timeout: .seconds(5))
            }
        }
    }

    private static func nonEventExperience(id: String, versionId: String) -> Experience {
        Experience(
            id: id,
            versionId: versionId,
            name: id,
            reentry: .everyTime,
            publishedAt: "2026-08-13T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
    }

    private static func releaseProfile(
        experienceId: String,
        versionId: String
    ) -> ExperienceReleaseProfileV1 {
        let digest = String(repeating: "a", count: 64)
        let envelope = ExperienceReleaseDescriptorEnvelopeV1(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: digest,
            descriptorSizeBytes: 2,
            descriptorBytesBase64: "e30=",
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: "test",
                signatureBase64: "signature"
            )
        )
        return .init(
            delivery: .init(
                renderBaseUrl: "https://cdn.nuxie.test/renders/",
                assetBaseUrl: "https://cdn.nuxie.test/assets/"
            ),
            active: [.init(
                locator: .init(
                    appId: "app_test",
                    environment: "test",
                    experienceId: experienceId,
                    experienceVersionId: versionId,
                    buildId: "signed-build",
                    versionNumber: 1,
                    publishedAt: "2026-08-13T00:00:00Z",
                    publishedAtSeq: 1
                ),
                descriptorSha256: digest,
                envelopeBytes: try! JSONEncoder().encode(envelope)
            )],
            pinned: []
        )
    }
}
