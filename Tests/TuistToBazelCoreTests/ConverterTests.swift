import Foundation
import XCTest
@testable import TuistToBazelCore

final class ConverterTests: XCTestCase {
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
