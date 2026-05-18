import XCTest
@testable import TuistToBazelCore

final class BazelGeneratorTests: XCTestCase {
    func testGeneratesAppFrameworkAndUnitTestRules() throws {
        let root = URL(fileURLWithPath: "/tmp/Fixture")
        let graph = TuistGraph(
            name: "Fixture",
            projects: [
                TuistProject(
                    name: "App",
                    path: "/tmp/Fixture/App",
                    targets: [
                        TuistTarget(
                            name: "App",
                            product: .app,
                            bundleId: "dev.tuist.App",
                            productName: "App",
                            projectPath: "/tmp/Fixture/App",
                            infoPlistPath: "/tmp/Fixture/App/Info.plist",
                            sources: ["/tmp/Fixture/App/Sources/App.swift"],
                            resources: [],
                            dependencies: [
                                .project(target: "Framework", path: "/tmp/Fixture/Framework"),
                                .target(name: "AppExtension"),
                                .framework(path: "/tmp/Fixture/App/Vendor/Prebuilt.framework"),
                            ]
                        ),
                        TuistTarget(
                            name: "AppExtension",
                            product: .appExtension,
                            bundleId: "dev.tuist.AppExtension",
                            productName: "AppExtension",
                            projectPath: "/tmp/Fixture/App",
                            infoPlistPath: "/tmp/Fixture/App/AppExtension/Info.plist",
                            sources: ["/tmp/Fixture/App/AppExtension/Extension.swift"],
                            resources: [],
                            dependencies: [.project(target: "Framework", path: "/tmp/Fixture/Framework")]
                        ),
                        TuistTarget(
                            name: "AppTests",
                            product: .unitTests,
                            bundleId: "dev.tuist.AppTests",
                            productName: "AppTests",
                            projectPath: "/tmp/Fixture/App",
                            infoPlistPath: "/tmp/Fixture/App/Tests.plist",
                            sources: ["/tmp/Fixture/App/Tests/AppTests.swift"],
                            resources: [],
                            dependencies: [.target(name: "App")]
                        ),
                    ]
                ),
                TuistProject(
                    name: "Framework",
                    path: "/tmp/Fixture/Framework",
                    targets: [
                        TuistTarget(
                            name: "Framework",
                            product: .framework,
                            bundleId: "dev.tuist.Framework",
                            productName: "Framework",
                            projectPath: "/tmp/Fixture/Framework",
                            infoPlistPath: "/tmp/Fixture/Framework/Info.plist",
                            sources: ["/tmp/Fixture/Framework/Sources/Framework.swift"],
                            resources: [],
                            dependencies: []
                        ),
                        TuistTarget(
                            name: "StaticFramework",
                            product: .staticFramework,
                            bundleId: "dev.tuist.StaticFramework",
                            productName: "StaticFramework",
                            projectPath: "/tmp/Fixture/Framework",
                            infoPlistPath: "/tmp/Fixture/Framework/StaticFramework.plist",
                            sources: ["/tmp/Fixture/Framework/Sources/StaticFramework.swift"],
                            resources: [],
                            dependencies: [.target(name: "Framework")]
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        XCTAssertTrue(rendered["App/BUILD.bazel"]?.contains("ios_application(") == true)
        XCTAssertTrue(rendered["App/BUILD.bazel"]?.contains("ios_extension(") == true)
        XCTAssertTrue(rendered["App/BUILD.bazel"]?.contains("apple_static_framework_import(") == true)
        XCTAssertTrue(rendered["App/BUILD.bazel"]?.contains("name = \"_PrebuiltImport\"") == true)
        XCTAssertTrue(rendered["App/BUILD.bazel"]?.contains("\":_PrebuiltImport\"") == true)
        XCTAssertTrue(rendered["App/BUILD.bazel"]?.contains("ios_unit_test(") == true)
        XCTAssertTrue(rendered["App/BUILD.bazel"]?.contains("tags = [\"manual\"]") == true)
        XCTAssertTrue(rendered["App/BUILD.bazel"]?.contains("test_host = \":App\"") == true)
        XCTAssertTrue(rendered["Framework/BUILD.bazel"]?.contains("ios_framework(") == true)
        XCTAssertTrue(rendered["Framework/BUILD.bazel"]?.contains("extension_safe = True") == true)
        XCTAssertTrue(rendered["Framework/BUILD.bazel"]?.contains("ios_static_framework(") == true)
        XCTAssertTrue(rendered["Framework/BUILD.bazel"]?.contains("avoid_deps =") == true)
        XCTAssertTrue(rendered["Framework/BUILD.bazel"]?.contains("\":FrameworkLib\"") == true)
    }
}
