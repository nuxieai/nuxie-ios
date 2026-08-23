import Foundation
@_spi(Testing) @testable import Nuxie

/// Builder for creating test profile responses with fluent API
class TestProfileResponseBuilder {
    private var experiences: [Experience] = []
    private var segments: [Segment] = []
    private var userProperties: [String: AnyCodable]?
    private var experiments: [String: ExperimentAssignment]?
    private var features: [Feature]?

    func withExperiences(_ experiences: [Experience]) -> TestProfileResponseBuilder {
        self.experiences = experiences
        return self
    }
    
    func addExperience(_ experience: Experience) -> TestProfileResponseBuilder {
        experiences.append(experience)
        return self
    }
    
    func withSegments(_ segments: [Segment]) -> TestProfileResponseBuilder {
        self.segments = segments
        return self
    }

    func addSegment(_ segment: Segment) -> TestProfileResponseBuilder {
        segments.append(segment)
        return self
    }
    
    func withUserProperties(_ properties: [String: AnyCodable]) -> TestProfileResponseBuilder {
        self.userProperties = properties
        return self
    }

    func withExperiments(_ experiments: [String: ExperimentAssignment]) -> TestProfileResponseBuilder {
        self.experiments = experiments
        return self
    }

    func withFeatures(_ features: [Feature]) -> TestProfileResponseBuilder {
        self.features = features
        return self
    }

    func build() -> ProfileResponse {
        _ = experiences
        return ProfileResponse(
            segments: segments,
            userProperties: userProperties,
            experiments: experiments,
            features: features
        )
    }
}
