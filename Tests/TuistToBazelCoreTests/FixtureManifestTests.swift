import XCTest

final class FixtureManifestTests: XCTestCase {
    func testManifestPointsAtPinnedTuistXcodeCorpus() throws {
        let manifest = try loadManifest()

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.upstream.repository, "https://github.com/tuist/tuist")
        XCTAssertFalse(manifest.upstream.commit.isEmpty)
        XCTAssertEqual(manifest.corpus.upstreamPath, "examples/xcode")
        XCTAssertEqual(manifest.corpus.localPath, "Fixtures/Tuist")
        XCTAssertEqual(manifest.corpus.syncStrategy, "selected-fixtures")
    }

    func testSyncedTuistCorpusMatchesSelectedManifestFixtures() throws {
        let manifest = try loadManifest()
        let corpusPrefix = "\(manifest.corpus.localPath)/"
        let selectedFixtures = manifest.fixtures.filter { $0.localPath.hasPrefix(corpusPrefix) }

        XCTAssertEqual(selectedFixtures.count, 29)

        for fixture in selectedFixtures {
            let fixtureURL = repoRoot.appendingPathComponent(fixture.localPath)
            var isDirectory = ObjCBool(false)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixtureURL.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "Missing synced Tuist fixture: \(fixture.name)"
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent(".upstream.json").path),
                "Missing upstream metadata for fixture: \(fixture.name)"
            )
        }

        let actualFixtureNames = try FileManager.default.contentsOfDirectory(
            at: repoRoot.appendingPathComponent(manifest.corpus.localPath),
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .map(\.lastPathComponent)
        .sorted()

        XCTAssertEqual(actualFixtureNames, selectedFixtures.map(\.name).sorted())
    }

    func testExamplesStayDeclaredAsSupportedShowcases() throws {
        let manifest = try loadManifest()
        let examples = manifest.showcases.filter { $0.localPath.hasPrefix("Examples/") }

        XCTAssertFalse(examples.isEmpty)
        for fixture in examples {
            XCTAssertEqual(fixture.category, "example")
            XCTAssertEqual(fixture.expectedStatus, "supported")
            XCTAssertTrue(fixture.expectedDiagnostics.isEmpty)
        }
    }

    func testSupportedFixturesHaveExecutableVerificationPlans() throws {
        let supportedFixtures = try loadManifest().fixtures.filter { $0.expectedStatus == "supported" }

        XCTAssertFalse(supportedFixtures.isEmpty)
        for fixture in supportedFixtures {
            let commands = fixture.verificationCommands ?? []
            XCTAssertFalse(commands.isEmpty, "Missing verification plan for \(fixture.name)")
            XCTAssertTrue(
                commands.contains { $0.hasPrefix("tuist graph ") },
                "Missing graph generation for \(fixture.name)"
            )
            XCTAssertTrue(
                commands.contains { $0.hasPrefix("tuist-to-bazel convert ") },
                "Missing conversion for \(fixture.name)"
            )
            XCTAssertTrue(
                commands.contains { $0.hasPrefix("bazelisk query ") },
                "Missing Bazel query for \(fixture.name)"
            )
            XCTAssertTrue(
                commands.contains { $0.hasPrefix("bazelisk build ") },
                "Missing Bazel build for \(fixture.name)"
            )
        }
    }

    private func loadManifest() throws -> FixtureManifest {
        let url = repoRoot.appendingPathComponent("Fixtures/manifest.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureManifest.self, from: data)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

private struct FixtureManifest: Decodable {
    let schemaVersion: Int
    let upstream: FixtureUpstream
    let corpus: FixtureCorpus
    let fixtures: [Fixture]
    let showcases: [FixtureShowcase]
}

private struct FixtureUpstream: Decodable {
    let repository: String
    let commit: String
}

private struct FixtureCorpus: Decodable {
    let upstreamPath: String
    let localPath: String
    let syncStrategy: String
}

private struct Fixture: Decodable {
    let name: String
    let localPath: String
    let category: String
    let expectedStatus: String
    let expectedDiagnostics: [String]
    let verificationCommands: [String]?
}

private struct FixtureShowcase: Decodable {
    let name: String
    let localPath: String
    let category: String
    let expectedStatus: String
    let expectedDiagnostics: [String]
}
