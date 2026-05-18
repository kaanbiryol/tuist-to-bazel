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

    func testGeneratesStaticLibraryDependenciesForProjectAndSwiftArchive() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-static-library-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let appProject = root
        let aProject = root.appendingPathComponent("Modules/A", isDirectory: true)
        let bProject = root.appendingPathComponent("Modules/B", isDirectory: true)
        let cPrebuilt = root.appendingPathComponent("Modules/C/prebuilt/C", isDirectory: true)
        let cSwiftModule = cPrebuilt.appendingPathComponent("C.swiftmodule", isDirectory: true)
        try fileManager.createDirectory(at: cSwiftModule, withIntermediateDirectories: true)
        try Data().write(to: cPrebuilt.appendingPathComponent("libC.a"))
        try Data().write(to: cSwiftModule.appendingPathComponent("arm64-apple-ios-simulator.swiftinterface"))
        try Data().write(to: cSwiftModule.appendingPathComponent("arm64-apple-ios-simulator.swiftdoc"))

        let graph = TuistGraph(
            name: "Fixture",
            projects: [
                TuistProject(
                    name: "App",
                    path: appProject.path,
                    targets: [
                        TuistTarget(
                            name: "App",
                            product: .app,
                            bundleId: "dev.tuist.App",
                            productName: "App",
                            projectPath: appProject.path,
                            infoPlistPath: nil,
                            sources: [appProject.appendingPathComponent("Sources/App.swift").path],
                            resources: [],
                            dependencies: [.project(target: "A", path: aProject.path)]
                        ),
                    ]
                ),
                TuistProject(
                    name: "A",
                    path: aProject.path,
                    targets: [
                        TuistTarget(
                            name: "A",
                            product: .staticLibrary,
                            bundleId: nil,
                            productName: "A",
                            projectPath: aProject.path,
                            infoPlistPath: nil,
                            sources: [aProject.appendingPathComponent("Sources/A.swift").path],
                            resources: [],
                            dependencies: [
                                .project(target: "B", path: bProject.path),
                                .library(
                                    path: cPrebuilt.appendingPathComponent("libC.a").path,
                                    publicHeaders: cPrebuilt.path,
                                    swiftModuleMap: cSwiftModule.path
                                ),
                            ]
                        ),
                    ]
                ),
                TuistProject(
                    name: "B",
                    path: bProject.path,
                    targets: [
                        TuistTarget(
                            name: "B",
                            product: .staticLibrary,
                            bundleId: nil,
                            productName: "B",
                            projectPath: bProject.path,
                            infoPlistPath: nil,
                            sources: [bProject.appendingPathComponent("Sources/B.swift").path],
                            resources: [],
                            dependencies: []
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        let aBuild = try XCTUnwrap(rendered["Modules/A/BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains("swift_import("))
        XCTAssertTrue(rootBuild.contains("name = \"_CImport\""))
        XCTAssertTrue(rootBuild.contains("swiftinterface = \"Modules/C/prebuilt/C/C.swiftmodule/arm64-apple-ios-simulator.swiftinterface\""))
        XCTAssertTrue(rootBuild.contains("tags = [\"manual\"]"))
        XCTAssertTrue(aBuild.contains("//Modules/B:B"))
        XCTAssertTrue(aBuild.contains("//:_CImport"))
        XCTAssertTrue(aBuild.contains("tags = [\"manual\"]"))
    }

    func testGeneratesXCFrameworkImports() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-xcframework-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let dynamicXCFramework = root.appendingPathComponent("Vendor/MyFramework.xcframework", isDirectory: true)
        try writeXCFrameworkInfo(at: dynamicXCFramework, libraryPath: "MyFramework.framework")
        try fileManager.createDirectory(
            at: dynamicXCFramework.appendingPathComponent("ios-arm64_x86_64-simulator/MyFramework.framework", isDirectory: true),
            withIntermediateDirectories: true
        )

        let staticXCFramework = root.appendingPathComponent("Vendor/MyStaticLibrary.xcframework", isDirectory: true)
        try writeXCFrameworkInfo(at: staticXCFramework, libraryPath: "libMyStaticLibrary.a")
        let staticModule = staticXCFramework.appendingPathComponent(
            "ios-arm64_x86_64-simulator/MyStaticLibrary.swiftmodule",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staticModule, withIntermediateDirectories: true)
        try Data().write(to: staticModule.appendingPathComponent("arm64-apple-ios-simulator.swiftinterface"))

        let graph = TuistGraph(
            name: "Fixture",
            projects: [
                TuistProject(
                    name: "App",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "App",
                            product: .app,
                            bundleId: "dev.tuist.App",
                            productName: "App",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("Sources/App.swift").path],
                            resources: [],
                            dependencies: [
                                .xcframework(path: dynamicXCFramework.path),
                                .xcframework(path: staticXCFramework.path),
                            ]
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains("apple_dynamic_xcframework_import("))
        XCTAssertTrue(rootBuild.contains("name = \"_MyFrameworkImport\""))
        XCTAssertTrue(rootBuild.contains("apple_static_xcframework_import("))
        XCTAssertTrue(rootBuild.contains("name = \"_MyStaticLibraryImport\""))
        XCTAssertTrue(rootBuild.contains("\"-swift.layering_check\""))
        XCTAssertTrue(rootBuild.contains("\"apple._import_framework_via_swiftinterface\""))
        XCTAssertTrue(rootBuild.contains("\":_MyFrameworkImport\""))
        XCTAssertTrue(rootBuild.contains("\":_MyStaticLibraryImport\""))
    }

    private func writeXCFrameworkInfo(at url: URL, libraryPath: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "AvailableLibraries": [
                [
                    "LibraryIdentifier": "ios-arm64_x86_64-simulator",
                    "LibraryPath": libraryPath,
                    "SupportedArchitectures": ["arm64", "x86_64"],
                    "SupportedPlatform": "ios",
                    "SupportedPlatformVariant": "simulator",
                ],
            ],
            "CFBundlePackageType": "XFWK",
            "XCFrameworkFormatVersion": "1.0",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Info.plist"))
    }
}
