import Foundation
import XCTest
@testable import TuistToBazelCore

final class ConverterTests: XCTestCase {
    func testRoutesTuistSwiftPackageCheckoutsThroughRulesSwiftPackageManager() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-external-package-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let appSources = root.appendingPathComponent("Sources", isDirectory: true)
        let checkout = root.appendingPathComponent("Tuist/.build/checkouts/Alamofire", isDirectory: true)
        let packageSources = checkout.appendingPathComponent("Source", isDirectory: true)
        try fileManager.createDirectory(at: appSources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: packageSources, withIntermediateDirectories: true)

        let appSource = appSources.appendingPathComponent("App.swift")
        let packageSource = packageSources.appendingPathComponent("Legacy.m")
        try "import Alamofire\n".write(to: appSource, atomically: true, encoding: .utf8)
        try "void legacy(void) {}\n".write(to: packageSource, atomically: true, encoding: .utf8)
        try """
        {
          "pins": [
            {
              "identity": "alamofire",
              "kind": "remoteSourceControl",
              "location": "https://github.com/Alamofire/Alamofire.git",
              "state": { "revision": "abc123", "version": "5.10.1" }
            }
          ],
          "version": 2
        }
        """.write(
            to: root.appendingPathComponent("Tuist/Package.resolved"),
            atomically: true,
            encoding: .utf8
        )

        let appTarget: [String: Any] = [
            "product": "app",
            "bundleId": "dev.tuist.App",
            "productName": "App",
            "sources": [["path": appSource.path]],
            "resources": ["resources": [Any]()],
            "dependencies": [
                ["project": ["target": "Alamofire", "path": checkout.path]],
            ],
        ]
        let packageTarget: [String: Any] = [
            "product": "staticFramework",
            "productName": "Alamofire",
            "sources": [["path": packageSource.path]],
            "resources": ["resources": [Any]()],
            "dependencies": [Any](),
        ]
        let graphObject: [String: Any] = [
            "name": "Fixture",
            "projects": [
                root.path: ["name": "Fixture", "targets": ["App": appTarget]],
                checkout.path: ["name": "Alamofire", "targets": ["Alamofire": packageTarget]],
            ],
            "packages": [Any](),
        ]
        let graph = root.appendingPathComponent("graph.json")
        try JSONSerialization.data(withJSONObject: graphObject, options: [.prettyPrinted]).write(to: graph)

        let result = try Converter().convert(
            ConversionInput(graphPath: graph, rootPath: root, outputPath: root, force: true)
        )
        let build = try String(contentsOf: root.appendingPathComponent("BUILD.bazel"), encoding: .utf8)
        let packageManifest = try String(
            contentsOf: root.appendingPathComponent(".bazel/SwiftPackages/Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(build.contains("@swiftpkg_alamofire//:Alamofire"))
        XCTAssertFalse(build.contains("Tuist/.build/checkouts/Alamofire"))
        XCTAssertTrue(
            packageManifest.contains(
                ".package(url: \"https://github.com/Alamofire/Alamofire.git\", .exact(\"5.10.1\"))"
            )
        )
        XCTAssertFalse(result.writtenFiles.contains(checkout.appendingPathComponent("BUILD.bazel")))
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(".bazelignore"), encoding: .utf8),
            "Tuist/.build/checkouts\n"
        )
    }

    func testPreflightsAllOutputConflictsBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let existingModule = fixture.root.appendingPathComponent("MODULE.bazel")
        try "existing module\n".write(to: existingModule, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try Converter().convert(
                ConversionInput(
                    graphPath: fixture.graph,
                    rootPath: fixture.root,
                    outputPath: fixture.root,
                    force: false
                )
            )
        ) { error in
            guard let conversionError = error as? ConversionError,
                  case let .outputExists(url) = conversionError else {
                return XCTFail("Expected outputExists, got \(error)")
            }
            XCTAssertEqual(url, existingModule)
        }

        XCTAssertEqual(try String(contentsOf: existingModule, encoding: .utf8), "existing module\n")
        let rootBuild = fixture.root.appendingPathComponent("BUILD.bazel")
        let generatedSupport = fixture.root.appendingPathComponent(".bazel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootBuild.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: generatedSupport.path))
    }

    private func makeFixture() throws -> (root: URL, graph: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-converter-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)

        let source = sources.appendingPathComponent("App.swift")
        try "import UIKit\n".write(to: source, atomically: true, encoding: .utf8)

        let target: [String: Any] = [
            "product": "app",
            "bundleId": "dev.tuist.App",
            "productName": "App",
            "sources": [["path": source.path]],
            "resources": ["resources": [Any]()],
            "dependencies": [Any](),
        ]
        let project: [String: Any] = [
            "name": "Fixture",
            "targets": ["App": target],
        ]
        let graphObject: [String: Any] = [
            "name": "Fixture",
            "projects": [root.path: project],
        ]
        let graph = root.appendingPathComponent("graph.json")
        try JSONSerialization.data(withJSONObject: graphObject, options: [.prettyPrinted]).write(to: graph)
        return (root, graph)
    }
}
