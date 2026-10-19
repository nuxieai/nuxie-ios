import Foundation
import XCTest
@testable import NuxieRuntime
@testable import Nuxie

final class ExperienceFoldEnvironmentTests: XCTestCase {
    func testEndpointsAndFractionsAreNormalizedWithoutLayoutAssumptions() {
        for (angle, state, expected) in [
            (0.4, ExperienceFoldEnvironment.State.closed, Float(0)),
            (2.0, .fullyOpen, Float(1)),
            (Double.pi / 2, .partiallyOpen, Float(0.5)),
            (Double.pi * 0.709876543, .partiallyOpen, Float(0.709876543)),
            (-2.0, .partiallyOpen, Float(0)),
            (5.0, .partiallyOpen, Float(1))
        ] {
            let value = ExperienceFoldEnvironment(angleRadians: angle, state: state)
            XCTAssertTrue(value.available)
            XCTAssertEqual(value.state, state)
            XCTAssertEqual(value.openProgress, expected, accuracy: 0.000001)
            XCTAssertEqual(value.openProgress + value.foldProgress, 1)
        }
    }

    func testMissingUnknownAndInvalidObservationsAreNeutralAndDistinct() {
        for (angle, state) in [
            (nil, ExperienceFoldEnvironment.State.unavailable),
            (Double.pi, .unknown),
            (Double.nan, .partiallyOpen),
            (Double.infinity, .closed)
        ] {
            let value = ExperienceFoldEnvironment(angleRadians: angle, state: state)
            XCTAssertFalse(value.available)
            XCTAssertEqual(value.state, state)
            XCTAssertEqual(value.openProgress, 1)
            XCTAssertEqual(value.foldProgress, 0)
        }
    }

    func testViewportUsesFiniteLogicalDimensions() {
        XCTAssertEqual(ExperienceViewportEnvironment(width: 466, height: 678).width, 466)
        XCTAssertEqual(ExperienceViewportEnvironment(width: .infinity, height: -1),
                       ExperienceViewportEnvironment(width: 0, height: 0))
    }

    #if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
    func testOlderEnvironmentArtifactsReceiveOnlyTheirDeclaredSlots() throws {
        let catalog = NuxieNativeViewModelCatalog(
            schemas: [.init(index: 0, name: "env", propertyRange: 0..<1,
                            authoredInstanceRange: 0..<0, defaultAuthoredInstance: nil, isGlobal: true)],
            properties: [.init(schemaIndex: 0, index: 0, name: "reduceMotion", kind: .bool,
                               referencedSchemaIndex: nil, enumLabels: [])], authoredInstances: [])
        let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: 1))
        let writes = ExperienceEnvironmentBindings(catalog: catalog).mutations(
            reference: reference, reduceMotion: true,
            viewport: .init(width: 466, height: 678),
            fold: .init(angleRadians: .pi / 2, state: .partiallyOpen))
        XCTAssertEqual(writes, [.setBool(instance: reference, path: "reduceMotion", value: true)])
    }

    func testFoldBatchUsesArtifactEnumLabelsAndComplementaryFractions() throws {
        let catalog = NuxieNativeViewModelCatalog(
            schemas: [
                .init(index: 0, name: "env", propertyRange: 0..<3,
                      authoredInstanceRange: 0..<0, defaultAuthoredInstance: nil, isGlobal: true),
                .init(index: 1, name: "fold", propertyRange: 3..<7,
                      authoredInstanceRange: 0..<0, defaultAuthoredInstance: nil, isGlobal: false)
            ], properties: [
                .init(schemaIndex: 0, index: 0, name: "width", kind: .number, referencedSchemaIndex: nil, enumLabels: []),
                .init(schemaIndex: 0, index: 1, name: "height", kind: .number, referencedSchemaIndex: nil, enumLabels: []),
                .init(schemaIndex: 0, index: 2, name: "fold", kind: .viewModel, referencedSchemaIndex: 1, enumLabels: []),
                .init(schemaIndex: 1, index: 0, name: "available", kind: .bool, referencedSchemaIndex: nil, enumLabels: []),
                .init(schemaIndex: 1, index: 1, name: "state", kind: .enumeration, referencedSchemaIndex: nil,
                      enumLabels: ["partially-open", "unavailable", "closed", "fully-open", "unknown"]),
                .init(schemaIndex: 1, index: 2, name: "openProgress", kind: .number, referencedSchemaIndex: nil, enumLabels: []),
                .init(schemaIndex: 1, index: 3, name: "foldProgress", kind: .number, referencedSchemaIndex: nil, enumLabels: [])
            ], authoredInstances: [])
        let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: 1))
        let writes = ExperienceEnvironmentBindings(catalog: catalog).mutations(
            reference: reference, viewport: .init(width: 466, height: 678),
            fold: .init(angleRadians: .pi / 4, state: .partiallyOpen))
        XCTAssertEqual(writes, [
            .setNumber(instance: reference, path: "width", value: 466),
            .setNumber(instance: reference, path: "height", value: 678),
            .setBool(instance: reference, path: "fold/available", value: true),
            .setNumber(instance: reference, path: "fold/openProgress", value: 0.25),
            .setNumber(instance: reference, path: "fold/foldProgress", value: 0.75),
            .setEnumeration(instance: reference, path: "fold/state", value: 0)
        ])
    }

    func testColorSchemeWritesTheIndexOfItsLabelInTheArtifactsOrder() throws {
        let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: 1))
        for labels in [["light", "dark"], ["dark", "light"]] {
            let catalog = NuxieNativeViewModelCatalog(
                schemas: [.init(index: 0, name: "env", propertyRange: 0..<2,
                                authoredInstanceRange: 0..<0, defaultAuthoredInstance: nil, isGlobal: true)],
                properties: [
                    .init(schemaIndex: 0, index: 0, name: "reduceMotion", kind: .bool,
                          referencedSchemaIndex: nil, enumLabels: []),
                    .init(schemaIndex: 0, index: 1, name: "colorScheme", kind: .enumeration,
                          referencedSchemaIndex: nil, enumLabels: labels)
                ], authoredInstances: [])
            let bindings = ExperienceEnvironmentBindings(catalog: catalog)
            for scheme in ExperienceColorScheme.allCases {
                let index = UInt64(try XCTUnwrap(labels.firstIndex(of: scheme.label)))
                XCTAssertEqual(bindings.mutations(reference: reference, reduceMotion: false, colorScheme: scheme), [
                    .setBool(instance: reference, path: "reduceMotion", value: false),
                    .setEnumeration(instance: reference, path: "colorScheme", value: index)
                ])
            }
        }
    }

    func testColorSchemeIsSkippedWhenTheArtifactDoesNotDeclareTheSlot() throws {
        let reference = try XCTUnwrap(NuxieNativeViewModelReference(rawValue: 1))
        for property in [
            nil,
            NuxieNativeViewModelCatalog.Property(schemaIndex: 0, index: 1, name: "colorScheme", kind: .string,
                                                 referencedSchemaIndex: nil, enumLabels: []),
            NuxieNativeViewModelCatalog.Property(schemaIndex: 0, index: 1, name: "colorScheme", kind: .enumeration,
                                                 referencedSchemaIndex: nil, enumLabels: ["day", "night"])
        ] {
            let catalog = NuxieNativeViewModelCatalog(
                schemas: [.init(index: 0, name: "env", propertyRange: 0..<2,
                                authoredInstanceRange: 0..<0, defaultAuthoredInstance: nil, isGlobal: true)],
                properties: [.init(schemaIndex: 0, index: 0, name: "reduceMotion", kind: .bool,
                                   referencedSchemaIndex: nil, enumLabels: [])] + [property].compactMap { $0 },
                authoredInstances: [])
            let bindings = ExperienceEnvironmentBindings(catalog: catalog)
            XCTAssertEqual(bindings.mutations(reference: reference, colorScheme: .dark), [])
            XCTAssertEqual(bindings.mutations(reference: reference, reduceMotion: true, colorScheme: .light),
                           [.setBool(instance: reference, path: "reduceMotion", value: true)])
        }
    }

    func testThemeSelectionPicksTheInstanceNamedForTheAppearance() {
        let bindings = ExperienceEnvironmentBindings(catalog: themeCatalog(instances: [
            .init(schemaIndex: 0, index: 0, name: "dark"),
            .init(schemaIndex: 1, index: 0, name: "light"),
            .init(schemaIndex: 1, index: 1, name: "dark")
        ]))
        XCTAssertEqual(bindings.themeSelection(for: .light),
                       NuxieNativeAuthoredGlobalSelection(schemaIndex: 1, authoredInstanceIndex: 0))
        XCTAssertEqual(bindings.themeSelection(for: .dark),
                       NuxieNativeAuthoredGlobalSelection(schemaIndex: 1, authoredInstanceIndex: 1),
                       "Only the Theme schema's own instances are candidates")
    }

    func testThemeSelectionFallsBackToTheSchemaDefaultWithoutANamedInstance() {
        let bindings = ExperienceEnvironmentBindings(catalog: themeCatalog(instances: [
            .init(schemaIndex: 1, index: 0, name: "light"),
            .init(schemaIndex: 1, index: 1, name: nil)
        ]))
        XCTAssertEqual(bindings.themeSelection(for: .light),
                       NuxieNativeAuthoredGlobalSelection(schemaIndex: 1, authoredInstanceIndex: 0))
        XCTAssertEqual(bindings.themeSelection(for: .dark),
                       NuxieNativeAuthoredGlobalSelection(schemaIndex: 1, authoredInstanceIndex: nil))
    }

    func testThemeSelectionIsAbsentWithoutAGlobalThemeSchema() {
        let instances: [NuxieNativeViewModelCatalog.AuthoredInstance] = [
            .init(schemaIndex: 1, index: 0, name: "light"), .init(schemaIndex: 1, index: 1, name: "dark")
        ]
        for catalog in [themeCatalog(name: "Brand", instances: instances),
                        themeCatalog(isGlobal: false, instances: instances)] {
            let bindings = ExperienceEnvironmentBindings(catalog: catalog)
            XCTAssertNil(bindings.themeSelection(for: .light))
            XCTAssertNil(bindings.themeSelection(for: .dark))
        }
    }

    private func themeCatalog(name: String = "Theme", isGlobal: Bool = true,
                              instances: [NuxieNativeViewModelCatalog.AuthoredInstance]) -> NuxieNativeViewModelCatalog {
        NuxieNativeViewModelCatalog(
            schemas: [
                .init(index: 0, name: "env", propertyRange: 0..<0,
                      authoredInstanceRange: 0..<0, defaultAuthoredInstance: nil, isGlobal: true),
                .init(index: 1, name: name, propertyRange: 0..<1,
                      authoredInstanceRange: 0..<instances.count, defaultAuthoredInstance: nil, isGlobal: isGlobal)
            ], properties: [
                .init(schemaIndex: 1, index: 0, name: "surface", kind: .color, referencedSchemaIndex: nil, enumLabels: [])
            ], authoredInstances: instances)
    }
    #endif
}
