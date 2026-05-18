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

    func testGeneratesTVOSAppAndTopShelfExtensionRules() throws {
        let root = URL(fileURLWithPath: "/tmp/TVFixture")
        let graph = TuistGraph(
            name: "TVFixture",
            projects: [
                TuistProject(
                    name: "App",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "App",
                            product: .app,
                            destinations: ["appleTv"],
                            bundleId: "dev.tuist.App",
                            productName: "App",
                            projectPath: root.path,
                            infoPlistPath: root.appendingPathComponent("Info.plist").path,
                            sources: [root.appendingPathComponent("Sources/AppDelegate.swift").path],
                            resources: [],
                            dependencies: [.target(name: "TopShelfExtension")]
                        ),
                        TuistTarget(
                            name: "TopShelfExtension",
                            product: .tvTopShelfExtension,
                            destinations: ["appleTv"],
                            bundleId: "dev.tuist.App.TopShelfExtension",
                            productName: "TopShelfExtension",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            infoPlistEntries: [
                                "NSExtension": .dictionary([
                                    "NSExtensionPointIdentifier": .string("com.apple.tv-top-shelf"),
                                ]),
                            ],
                            sources: [root.appendingPathComponent("TopShelfExtension/ContentProvider.swift").path],
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
        XCTAssertTrue(rootBuild.contains("load(\"@build_bazel_rules_apple//apple:tvos.bzl\", \"tvos_application\", \"tvos_extension\")"))
        XCTAssertTrue(rootBuild.contains("tvos_application("))
        XCTAssertTrue(rootBuild.contains("families = [\"tv\"]"))
        XCTAssertTrue(rootBuild.contains("extensions = ["))
        XCTAssertTrue(rootBuild.contains("\":TopShelfExtension\""))
        XCTAssertTrue(rootBuild.contains("tvos_extension("))
        XCTAssertTrue(rootBuild.contains("target_environments = [\"simulator\"]"))
        XCTAssertTrue(rendered[".bazel/InfoPlists/TopShelfExtension-Info.plist"]?.contains("com.apple.tv-top-shelf") == true)
    }

    func testGeneratesSwiftCompilerPluginsForMacroTargets() throws {
        let root = URL(fileURLWithPath: "/tmp/MacroFixture")
        let graph = TuistGraph(
            name: "MacroFixture",
            projects: [
                TuistProject(
                    name: "Framework",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "Framework",
                            product: .framework,
                            destinations: ["mac"],
                            bundleId: "dev.tuist.Framework",
                            productName: "Framework",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("Sources/Framework.swift").path],
                            resources: [],
                            dependencies: [.target(name: "FrameworkMacros")]
                        ),
                        TuistTarget(
                            name: "FrameworkMacros",
                            product: .macro,
                            destinations: ["mac"],
                            bundleId: "dev.tuist.FrameworkMacros",
                            productName: "FrameworkMacros",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("Sources/FrameworkMacros/Plugin.swift").path],
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
        XCTAssertTrue(rootBuild.contains("load(\"@build_bazel_rules_swift//swift:swift.bzl\", \"swift_compiler_plugin\", \"swift_library\")"))
        XCTAssertTrue(rootBuild.contains("swift_compiler_plugin(\n    name = \"FrameworkMacros\""))
        XCTAssertTrue(rootBuild.contains("swift_library(\n    name = \"FrameworkLib\""))
        XCTAssertTrue(rootBuild.contains("plugins = [\n        \":FrameworkMacros\","))
        XCTAssertTrue(rootBuild.contains("macos_framework("))
        XCTAssertTrue(rootBuild.contains("top_level_target(\n            \"//:Framework\""))
    }

    func testAddsDeveloperSearchPathsForUnconditionalXCTestImports() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-xctest-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let sources = root.appendingPathComponent("Sources/TestSupport", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        import XCTest

        public func assertSomething(_ value: Bool) {
            XCTAssertTrue(value)
        }
        """.write(to: sources.appendingPathComponent("TestSupport.swift"), atomically: true, encoding: .utf8)

        let graph = TuistGraph(
            name: "XCTestImportFixture",
            projects: [
                TuistProject(
                    name: "Support",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "TestSupport",
                            product: .staticLibrary,
                            bundleId: nil,
                            productName: "TestSupport",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [sources.appendingPathComponent("TestSupport.swift").path],
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
        XCTAssertTrue(rootBuild.contains("always_include_developer_search_paths = True"))
        XCTAssertTrue(rootBuild.contains("linkopts = [\n        \"-framework\",\n        \"XCTest\","))
    }

    func testGeneratesLocalSwiftPackageDependencies() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-local-spm-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let package = root.appendingPathComponent("Packages/PackageA", isDirectory: true)
        let libraryA = package.appendingPathComponent("Sources/LibraryA", isDirectory: true)
        let libraryB = package.appendingPathComponent("Sources/LibraryB", isDirectory: true)
        try fileManager.createDirectory(at: libraryA, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: libraryB, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "PackageA",
            products: [
                .library(name: "LibraryA", targets: ["LibraryA"]),
                .library(name: "LibraryB", targets: ["LibraryB"]),
            ],
            targets: [
                .target(name: "LibraryA", dependencies: []),
                .target(name: "LibraryB", dependencies: []),
            ]
        )
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "public struct LibraryAType {}\n".write(
            to: libraryA.appendingPathComponent("LibraryA.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "public struct LibraryBType {}\n".write(
            to: libraryB.appendingPathComponent("LibraryB.swift"),
            atomically: true,
            encoding: .utf8
        )

        let graph = TuistGraph(
            name: "LocalSPMFixture",
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
                                .package(product: "LibraryA"),
                                .package(product: "LibraryB"),
                            ]
                        ),
                    ]
                ),
            ],
            localSwiftPackages: [TuistLocalSwiftPackage(path: package.path)]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let result = try generator.render()
        let rendered = result.files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        let packageBuild = try XCTUnwrap(rendered["Packages/PackageA/BUILD.bazel"])
        XCTAssertFalse(result.warnings.contains { $0.contains("package dependency") })
        XCTAssertTrue(rootBuild.contains("//Packages/PackageA:LibraryA"))
        XCTAssertTrue(rootBuild.contains("//Packages/PackageA:LibraryB"))
        XCTAssertTrue(packageBuild.contains("swift_library(\n    name = \"LibraryA\""))
        XCTAssertTrue(packageBuild.contains("Sources/LibraryA/LibraryA.swift"))
        XCTAssertTrue(packageBuild.contains("swift_library(\n    name = \"LibraryB\""))
        XCTAssertTrue(packageBuild.contains("Sources/LibraryB/LibraryB.swift"))
    }

    func testGeneratesLocalBinarySwiftPackageDependencies() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-local-binary-spm-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let package = root.appendingPathComponent("Packages/LocalPackage", isDirectory: true)
        let xcframework = package.appendingPathComponent("MyFramework/prebuilt/MyFramework.xcframework", isDirectory: true)
        let swiftModule = xcframework.appendingPathComponent(
            "ios-arm64_x86_64-simulator/MyFramework.framework/Modules/MyFramework.swiftmodule",
            isDirectory: true
        )
        try fileManager.createDirectory(at: swiftModule, withIntermediateDirectories: true)
        try Data().write(to: swiftModule.appendingPathComponent("arm64-apple-ios-simulator.swiftinterface"))
        try writeXCFrameworkInfo(at: xcframework, libraryPath: "MyFramework.framework")
        try """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "LocalPackage",
            products: [
                .library(name: "MyFramework", targets: ["MyFramework"]),
            ],
            targets: [
                .binaryTarget(
                    name: "MyFramework",
                    path: "MyFramework/prebuilt/MyFramework.xcframework"
                ),
            ]
        )
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)

        let graph = TuistGraph(
            name: "LocalBinarySPMFixture",
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
                            dependencies: [.package(product: "MyFramework")]
                        ),
                    ]
                ),
            ],
            localSwiftPackages: [TuistLocalSwiftPackage(path: package.path)]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let result = try generator.render()
        let rendered = result.files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        let packageBuild = try XCTUnwrap(rendered["Packages/LocalPackage/BUILD.bazel"])
        XCTAssertFalse(result.warnings.contains { $0.contains("package dependency") })
        XCTAssertTrue(rootBuild.contains("//Packages/LocalPackage:MyFramework"))
        XCTAssertTrue(packageBuild.contains("load(\"@build_bazel_rules_apple//apple:apple.bzl\", \"apple_dynamic_xcframework_import\")"))
        XCTAssertTrue(packageBuild.contains("apple_dynamic_xcframework_import(\n    name = \"MyFramework\""))
        XCTAssertTrue(packageBuild.contains("features = ["))
        XCTAssertTrue(packageBuild.contains("\"-swift.layering_check\""))
        XCTAssertTrue(packageBuild.contains("xcframework_imports = glob([\"MyFramework/prebuilt/MyFramework.xcframework/**\"])"))
    }

    func testGeneratesRemoteSwiftPackageDependencies() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-remote-spm-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        {
          "object": {
            "pins": [
              {
                "package": "RxSwift",
                "repositoryURL": "https://github.com/ReactiveX/RxSwift",
                "state": {
                  "branch": null,
                  "revision": "b3e888b4972d9bc76495dd74d30a8c7fad4b9395",
                  "version": "5.0.1"
                }
              }
            ]
          },
          "version": 1
        }
        """.write(to: root.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)

        let graph = TuistGraph(
            name: "RemoteSPMFixture",
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
                                .package(product: "RxSwift"),
                                .package(product: "RxBlocking"),
                            ]
                        ),
                    ]
                ),
            ],
            remoteSwiftPackages: [
                TuistRemoteSwiftPackage(url: "https://github.com/ReactiveX/RxSwift", requirement: .upToNextMajor("5.0.0")),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let result = try generator.render()
        let rendered = result.files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        let module = try XCTUnwrap(rendered["MODULE.bazel"])
        let packageSwift = try XCTUnwrap(rendered[".bazel/SwiftPackages/Package.swift"])
        let packageResolved = try XCTUnwrap(rendered[".bazel/SwiftPackages/Package.resolved"])
        XCTAssertFalse(result.warnings.contains { $0.contains("package dependency") })
        XCTAssertTrue(rootBuild.contains("@swiftpkg_rxswift//:RxSwift"))
        XCTAssertTrue(rootBuild.contains("@swiftpkg_rxswift//:RxBlocking"))
        XCTAssertTrue(module.contains("swift_deps.from_package("))
        XCTAssertTrue(module.contains("\"swiftpkg_rxswift\""))
        XCTAssertTrue(packageSwift.contains(".package(url: \"https://github.com/ReactiveX/RxSwift\", .upToNextMajor(from: \"5.0.0\"))"))
        XCTAssertTrue(packageResolved.contains("\"identity\" : \"rxswift\""))
    }

    func testGeneratesLocalSwiftPackageTransitiveRemoteDependencies() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-local-remote-spm-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let package = root.appendingPathComponent("LocalSwiftPackage", isDirectory: true)
        let sources = package.appendingPathComponent("Sources/LocalSwiftPackage", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // swift-tools-version: 5.10
        import PackageDescription

        let package = Package(
            name: "LocalSwiftPackage",
            products: [
                .library(name: "LocalSwiftPackage", targets: ["LocalSwiftPackage"]),
            ],
            dependencies: [
                .package(url: "https://github.com/apple/swift-collections", from: "1.0.0"),
            ],
            targets: [
                .target(
                    name: "LocalSwiftPackage",
                    dependencies: [
                        .product(name: "Collections", package: "swift-collections"),
                    ]
                ),
            ]
        )
        """.write(to: package.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        {
          "pins" : [
            {
              "identity" : "swift-collections",
              "kind" : "remoteSourceControl",
              "location" : "https://github.com/apple/swift-collections",
              "state" : {
                "revision" : "7b847a3b7008b2dc2f47ca3110d8c782fb2e5c7e",
                "version" : "1.3.0"
              }
            }
          ],
          "version" : 2
        }
        """.write(to: package.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)
        try "import Collections\npublic struct LocalType {}\n".write(
            to: sources.appendingPathComponent("LocalSwiftPackage.swift"),
            atomically: true,
            encoding: .utf8
        )

        let graph = TuistGraph(
            name: "LocalRemoteSPMFixture",
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
                            sources: [root.appendingPathComponent("App/Sources/App.swift").path],
                            resources: [],
                            dependencies: [.package(product: "LocalSwiftPackage")]
                        ),
                    ]
                ),
            ],
            localSwiftPackages: [TuistLocalSwiftPackage(path: package.path)]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let module = try XCTUnwrap(rendered["MODULE.bazel"])
        let packageBuild = try XCTUnwrap(rendered["LocalSwiftPackage/BUILD.bazel"])
        let packageSwift = try XCTUnwrap(rendered[".bazel/SwiftPackages/Package.swift"])
        XCTAssertTrue(module.contains("\"swiftpkg_swift_collections\""))
        XCTAssertTrue(packageBuild.contains("@swiftpkg_swift_collections//:Collections"))
        XCTAssertTrue(packageSwift.contains(".package(url: \"https://github.com/apple/swift-collections\", .upToNextMajor(from: \"1.0.0\"))"))
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

    func testAddsBinaryImportDepsForImportedModules() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-xcframework-source-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let xcframework = root.appendingPathComponent("Vendor/MyFramework.xcframework", isDirectory: true)
        try writeXCFrameworkInfo(at: xcframework, libraryPath: "MyFramework.framework")
        try fileManager.createDirectory(
            at: xcframework.appendingPathComponent("ios-arm64_x86_64-simulator/MyFramework.framework", isDirectory: true),
            withIntermediateDirectories: true
        )

        let appSources = root.appendingPathComponent("App/Sources", isDirectory: true)
        let frameworkSources = root.appendingPathComponent("Framework/Sources", isDirectory: true)
        try fileManager.createDirectory(at: appSources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: frameworkSources, withIntermediateDirectories: true)
        try "import MyFramework\nstruct AppType {}\n".write(
            to: appSources.appendingPathComponent("App.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "import MyFramework\npublic struct FrameworkType {}\n".write(
            to: frameworkSources.appendingPathComponent("Framework.swift"),
            atomically: true,
            encoding: .utf8
        )

        let graph = TuistGraph(
            name: "Fixture",
            projects: [
                TuistProject(
                    name: "Fixture",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "App",
                            product: .app,
                            bundleId: "dev.tuist.App",
                            productName: "App",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [appSources.appendingPathComponent("App.swift").path],
                            resources: [],
                            dependencies: [.target(name: "Framework")]
                        ),
                        TuistTarget(
                            name: "Framework",
                            product: .framework,
                            bundleId: "dev.tuist.Framework",
                            productName: "Framework",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [frameworkSources.appendingPathComponent("Framework.swift").path],
                            resources: [],
                            dependencies: [.xcframework(path: xcframework.path)]
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains("name = \"AppLib\""))
        XCTAssertTrue(rootBuild.contains("\":_MyFrameworkImport\""))
        XCTAssertTrue(rootBuild.contains("name = \"FrameworkLib\""))
        XCTAssertTrue(rootBuild.contains("deps = [\n        \":_MyFrameworkImport\","))
    }

    func testGeneratesSDKAndMixedLanguageAttributes() throws {
        let root = URL(fileURLWithPath: "/tmp/SDKFixture")
        let staticProject = root.appendingPathComponent("Modules/StaticFramework", isDirectory: true)
        let graph = TuistGraph(
            name: "Fixture",
            projects: [
                TuistProject(
                    name: "App",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "MyTestFramework",
                            product: .framework,
                            bundleId: "dev.tuist.MyTestFramework",
                            productName: "MyTestFramework",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("MyTestFramework/MyTestHelper.swift").path],
                            resources: [],
                            dependencies: [.xctest]
                        ),
                    ]
                ),
                TuistProject(
                    name: "StaticFramework",
                    path: staticProject.path,
                    targets: [
                        TuistTarget(
                            name: "StaticFramework",
                            product: .staticFramework,
                            bundleId: "dev.tuist.StaticFramework",
                            productName: "StaticFramework",
                            projectPath: staticProject.path,
                            infoPlistPath: nil,
                            sources: [
                                staticProject.appendingPathComponent("Sources/FrameworkClass.swift").path,
                                staticProject.appendingPathComponent("Sources/MyObjcppClass.mm").path,
                            ],
                            headers: TuistHeaders(
                                publicHeaders: [
                                    staticProject.appendingPathComponent("Sources/MyObjcppClass.h").path,
                                    staticProject.appendingPathComponent("Sources/StaticFramework.h").path,
                                ],
                                privateHeaders: [],
                                projectHeaders: []
                            ),
                            resources: [],
                            dependencies: [.sdk(name: "libc++.tbd", status: "required")]
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        let staticBuild = try XCTUnwrap(rendered["Modules/StaticFramework/BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains("infoplists = [\".bazel/InfoPlists/MyTestFramework-Info.plist\"]"))
        XCTAssertTrue(rootBuild.contains("always_include_developer_search_paths = True"))
        XCTAssertTrue(rootBuild.contains("\"-framework\""))
        XCTAssertTrue(rootBuild.contains("\"XCTest\""))
        XCTAssertTrue(staticBuild.contains("mixed_language_library("))
        XCTAssertTrue(staticBuild.contains("clang_srcs ="))
        XCTAssertTrue(staticBuild.contains("Sources/MyObjcppClass.mm"))
        XCTAssertTrue(staticBuild.contains("hdrs ="))
        XCTAssertTrue(staticBuild.contains("Sources/MyObjcppClass.h"))
        XCTAssertTrue(staticBuild.contains("sdk_dylibs ="))
        XCTAssertTrue(staticBuild.contains("\"c++\""))
        XCTAssertFalse(staticBuild.contains("umbrella_header ="))
    }

    func testGeneratesObjCLibraryForClangOnlyTargets() throws {
        let root = URL(fileURLWithPath: "/tmp/ObjCOnlyFixture")
        let graph = TuistGraph(
            name: "ObjCOnlyFixture",
            projects: [
                TuistProject(
                    name: "ObjCOnlyFixture",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "ObjCWrapper",
                            product: .staticFramework,
                            bundleId: "dev.tuist.ObjCWrapper",
                            productName: "ObjCWrapper",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("Sources/ObjCWrapper.m").path],
                            headers: TuistHeaders(
                                publicHeaders: [root.appendingPathComponent("Sources/ObjCWrapperSupport.h").path],
                                privateHeaders: [],
                                projectHeaders: []
                            ),
                            resources: [],
                            dependencies: [.sdk(name: "QuartzCore.framework", status: "required")]
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains("objc_library("))
        XCTAssertTrue(rootBuild.contains("srcs = [\n        \"Sources/ObjCWrapper.m\""))
        XCTAssertTrue(rootBuild.contains("hdrs = [\n        \"Sources/ObjCWrapperSupport.h\""))
        XCTAssertTrue(rootBuild.contains("sdk_frameworks = [\n        \"QuartzCore\""))
        XCTAssertTrue(rootBuild.contains("ios_static_framework("))
        XCTAssertFalse(rootBuild.contains("mixed_language_library("))
    }

    func testOmitsObjCAutoLinkingStubSources() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-objc-autolink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let sources = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        try """
        // Trigger auto-linking if MyFramework is never imported in the app.
        @import MyFramework;
        """.write(to: sources.appendingPathComponent("GMSEmpty.m"), atomically: true, encoding: .utf8)

        let xcframework = root.appendingPathComponent("Vendor/MyFramework.xcframework", isDirectory: true)
        try writeXCFrameworkInfo(at: xcframework, libraryPath: "MyFramework.framework")
        try fileManager.createDirectory(
            at: xcframework.appendingPathComponent("ios-arm64_x86_64-simulator/MyFramework.framework", isDirectory: true),
            withIntermediateDirectories: true
        )

        let graph = TuistGraph(
            name: "ObjCAutolinkFixture",
            projects: [
                TuistProject(
                    name: "ObjCAutolinkFixture",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "ObjCWrapper",
                            product: .staticFramework,
                            bundleId: "dev.tuist.ObjCWrapper",
                            productName: "ObjCWrapper",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [sources.appendingPathComponent("GMSEmpty.m").path],
                            headers: TuistHeaders(
                                publicHeaders: [sources.appendingPathComponent("ObjCWrapperSupport.h").path],
                                privateHeaders: [],
                                projectHeaders: []
                            ),
                            resources: [],
                            dependencies: [.xcframework(path: xcframework.path)]
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains("objc_library("))
        XCTAssertTrue(rootBuild.contains("srcs = [\n        \".bazel/Generated/ObjCWrapperObjCStub.m\""))
        XCTAssertFalse(rootBuild.contains("Sources/GMSEmpty.m"))
        XCTAssertTrue(rootBuild.contains("\":_MyFrameworkImport\""))
    }

    func testGeneratesMacOSFrameworkForMacOnlyDestinations() throws {
        let root = URL(fileURLWithPath: "/tmp/PlatformFixture")
        let graph = TuistGraph(
            name: "Fixture",
            projects: [
                TuistProject(
                    name: "Framework",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "Shared-iOS",
                            product: .framework,
                            destinations: ["iPhone", "iPad", "macWithiPadDesign"],
                            bundleId: "dev.tuist.Shared",
                            productName: "Shared",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("Sources/Shared.swift").path],
                            resources: [],
                            dependencies: []
                        ),
                        TuistTarget(
                            name: "Shared-macOS",
                            product: .framework,
                            destinations: ["mac"],
                            bundleId: "dev.tuist.Shared",
                            productName: "Shared",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("Sources/Shared.swift").path],
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
        XCTAssertTrue(rootBuild.contains("load(\"@build_bazel_rules_apple//apple:ios.bzl\", \"ios_framework\")"))
        XCTAssertTrue(rootBuild.contains("load(\"@build_bazel_rules_apple//apple:macos.bzl\", \"macos_framework\")"))
        XCTAssertTrue(rootBuild.contains("ios_framework(\n    name = \"Shared-iOS\""))
        XCTAssertTrue(rootBuild.contains("macos_framework(\n    name = \"Shared-macOS\""))
        XCTAssertTrue(rootBuild.contains("minimum_os_version = \"14.0\""))
    }

    func testGeneratesWatchApplicationEmbeddingRules() throws {
        let root = URL(fileURLWithPath: "/tmp/WatchAppFixture")
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
                            destinations: ["iPhone", "iPad"],
                            bundleId: "dev.tuist.App",
                            productName: "App",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("App/Sources/App.swift").path],
                            resources: [],
                            dependencies: [
                                .target(name: "WatchApp"),
                                .target(name: "Framework_a_ios"),
                            ]
                        ),
                        TuistTarget(
                            name: "Framework_a_ios",
                            product: .framework,
                            destinations: ["iPhone", "iPad"],
                            bundleId: "dev.tuist.framework.a",
                            productName: "FrameworkA",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [],
                            resources: [],
                            dependencies: []
                        ),
                        TuistTarget(
                            name: "Framework_a_watchos",
                            product: .framework,
                            destinations: ["appleWatch"],
                            bundleId: "dev.tuist.framework.a",
                            productName: "FrameworkA",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [],
                            resources: [],
                            dependencies: []
                        ),
                        TuistTarget(
                            name: "WatchApp",
                            product: .app,
                            destinations: ["appleWatch"],
                            bundleId: "dev.tuist.App.watchkitapp",
                            productName: "WatchApp",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            infoPlistEntries: [
                                "CFBundleVersion": .string("1.0"),
                                "WKCompanionAppBundleIdentifier": .string("dev.tuist.App"),
                            ],
                            sources: [root.appendingPathComponent("WatchApp/Sources/WatchApp.swift").path],
                            resources: [],
                            dependencies: [
                                .target(name: "WatchWidgetExtension"),
                                .target(name: "Framework_a_watchos"),
                            ]
                        ),
                        TuistTarget(
                            name: "WatchWidgetExtension",
                            product: .appExtension,
                            destinations: ["appleWatch"],
                            bundleId: "dev.tuist.App.watchkitapp.widgetExtension",
                            productName: "WatchWidgetExtension",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            infoPlistEntries: [
                                "NSExtension": .dictionary([
                                    "NSExtensionPointIdentifier": .string("com.apple.widgetkit-extension"),
                                ]),
                            ],
                            sources: [root.appendingPathComponent("WatchWidgetExtension/Sources/Widget.swift").path],
                            resources: [],
                            dependencies: [.target(name: "Framework_a_watchos")]
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains("watch_application = \":WatchApp\""))
        XCTAssertTrue(rootBuild.contains("watchos_application(\n    name = \"WatchApp\""))
        XCTAssertTrue(rootBuild.contains("watchos_extension(\n    name = \"WatchWidgetExtension\""))
        XCTAssertTrue(rootBuild.contains("application_extension = True"))
        XCTAssertTrue(rootBuild.contains("bundle_name = \"FrameworkA\""))
        XCTAssertFalse(rootBuild.contains("Framework_a_iosLib"))
        XCTAssertFalse(rootBuild.contains("Framework_a_watchosLib"))

        let appLib = try XCTUnwrap(firstRule(named: "AppLib", in: rootBuild))
        XCTAssertFalse(appLib.contains("WatchAppLib"))

        let watchAppPlist = try XCTUnwrap(rendered[".bazel/InfoPlists/WatchApp-Info.plist"])
        XCTAssertTrue(watchAppPlist.contains("WKCompanionAppBundleIdentifier"))
        let extensionPlist = try XCTUnwrap(rendered[".bazel/InfoPlists/WatchWidgetExtension-Info.plist"])
        XCTAssertTrue(extensionPlist.contains("<key>CFBundleVersion</key>"))
        XCTAssertTrue(extensionPlist.contains("<string>1.0</string>"))
    }

    func testGeneratesBundleModuleAccessorWhenResourceSourceUsesBundleModule() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-buildable-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let source = root.appendingPathComponent("Modules/Framework/Sources/Provider.swift")
        let resources = root.appendingPathComponent("Modules/Framework/Resources", isDirectory: true)
        let assets = resources.appendingPathComponent("Assets.xcassets", isDirectory: true)
        let imageSet = assets.appendingPathComponent("logo.imageset", isDirectory: true)
        let nested = resources.appendingPathComponent("Nested.bundle", isDirectory: true)
        try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: imageSet, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        try """
        import Foundation

        enum Provider {
            static let bundle = Bundle.module
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        try #"{"images":[],"info":{"author":"xcode","version":1}}"#.write(
            to: imageSet.appendingPathComponent("Contents.json"),
            atomically: true,
            encoding: .utf8
        )
        let rootInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Framework"],
            format: .xml,
            options: 0
        )
        try rootInfo.write(to: resources.appendingPathComponent("Info.plist"))
        let nestedInfo = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleName": "Nested"],
            format: .xml,
            options: 0
        )
        try nestedInfo.write(to: nested.appendingPathComponent("Info.plist"))

        let graph = TuistGraph(
            name: "Fixture",
            projects: [
                TuistProject(
                    name: "Framework",
                    path: root.path,
                    targets: [
                        TuistTarget(
                            name: "Framework",
                            product: .framework,
                            bundleId: "dev.tuist.Framework",
                            productName: "Framework",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [source.path],
                            resources: [TuistResource(path: resources.path, kind: .file, tags: [])],
                            dependencies: []
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains(".bazel/Generated/FrameworkResourceAccessors.swift"))
        let accessors = try XCTUnwrap(rendered[".bazel/Generated/FrameworkResourceAccessors.swift"])
        XCTAssertTrue(accessors.contains("static var module: Bundle"))
        XCTAssertEqual(accessors.components(separatedBy: "public enum Info").count - 1, 1)
    }

    func testGeneratesExtensionProductRulesAndPlists() throws {
        let root = URL(fileURLWithPath: "/tmp/ExtensionFixture")
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
                                .target(name: "NotificationServiceExtension"),
                                .target(name: "AppIntentExtension"),
                                .target(name: "StickersPackExtension"),
                            ]
                        ),
                        TuistTarget(
                            name: "AppWithMessagesExtension",
                            product: .app,
                            bundleId: "dev.tuist.App2",
                            productName: "AppWithMessagesExtension",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            sources: [root.appendingPathComponent("Sources/App.swift").path],
                            resources: [],
                            dependencies: [
                                .target(name: "MessageExtension"),
                                .target(name: "NotificationServiceExtension"),
                            ]
                        ),
                        TuistTarget(
                            name: "NotificationServiceExtension",
                            product: .appExtension,
                            bundleId: "dev.tuist.App.NotificationServiceExtension",
                            productName: "NotificationServiceExtension",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            infoPlistEntries: [
                                "CFBundleDisplayName": .string("$(PRODUCT_NAME)"),
                                "NSExtension": .dictionary([
                                    "NSExtensionPointIdentifier": .string("com.apple.usernotifications.service"),
                                    "NSExtensionPrincipalClass": .string("$(PRODUCT_MODULE_NAME).NotificationService"),
                                ]),
                            ],
                            sources: [root.appendingPathComponent("NotificationServiceExtension/NotificationService.swift").path],
                            resources: [],
                            dependencies: []
                        ),
                        TuistTarget(
                            name: "AppIntentExtension",
                            product: .extensionKitExtension,
                            bundleId: "dev.tuist.App.AppIntentExtension",
                            productName: "AppIntentExtension",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            infoPlistEntries: [
                                "EXAppExtensionAttributes": .dictionary([
                                    "EXExtensionPointIdentifier": .string("com.apple.appintents-extension"),
                                ]),
                            ],
                            sources: [root.appendingPathComponent("AppIntentExtension/Sources/AppIntent.swift").path],
                            resources: [],
                            dependencies: []
                        ),
                        TuistTarget(
                            name: "MessageExtension",
                            product: .messagesExtension,
                            bundleId: "dev.tuist.App2.MessageExtension",
                            productName: "MessageExtension",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            infoPlistEntries: [
                                "NSExtension": .dictionary([
                                    "NSExtensionMainStoryboard": .string("MainInterface"),
                                    "NSExtensionPointIdentifier": .string("com.apple.message-payload-provider"),
                                ]),
                            ],
                            sources: [root.appendingPathComponent("MessageExtension/Sources/MessagesViewController.swift").path],
                            resources: [
                                TuistResource(
                                    path: root.appendingPathComponent("MessageExtension/Resources/Base.lproj/MainInterface.storyboard").path,
                                    kind: .file,
                                    tags: []
                                ),
                            ],
                            dependencies: []
                        ),
                        TuistTarget(
                            name: "StickersPackExtension",
                            product: .stickerPackExtension,
                            bundleId: "dev.tuist.App.StickersPackExtension",
                            productName: "StickersPackExtension",
                            projectPath: root.path,
                            infoPlistPath: nil,
                            infoPlistEntries: [
                                "NSExtension": .dictionary([
                                    "NSExtensionPointIdentifier": .string("com.apple.message-payload-provider"),
                                ]),
                            ],
                            sources: [],
                            resources: [
                                TuistResource(
                                    path: root.appendingPathComponent("StickersPackExtension/Stickers.xcassets").path,
                                    kind: .file,
                                    tags: []
                                ),
                            ],
                            dependencies: []
                        ),
                    ]
                ),
            ]
        )

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        let rootBuild = try XCTUnwrap(rendered["BUILD.bazel"])
        XCTAssertTrue(rootBuild.contains("ios_extension("))
        XCTAssertTrue(rootBuild.contains("extensionkit_extension = True"))
        XCTAssertTrue(rootBuild.contains("ios_imessage_extension("))
        XCTAssertTrue(rootBuild.contains("ios_sticker_pack_extension("))
        XCTAssertTrue(rootBuild.contains("name = \"_AppWithMessagesExtension_NotificationServiceExtension\""))
        XCTAssertTrue(rootBuild.contains("bundle_id = \"dev.tuist.App2.NotificationServiceExtension\""))
        XCTAssertTrue(rootBuild.contains("executable_name = \"NotificationServiceExtension\""))
        XCTAssertTrue(rootBuild.contains("\":_AppWithMessagesExtension_NotificationServiceExtension\""))

        let notificationPlist = try XCTUnwrap(rendered[".bazel/InfoPlists/NotificationServiceExtension-Info.plist"])
        XCTAssertTrue(notificationPlist.contains("NotificationServiceExtension.NotificationService"))
        let wrapperPlist = try XCTUnwrap(rendered[".bazel/InfoPlists/_AppWithMessagesExtension_NotificationServiceExtension-Info.plist"])
        XCTAssertTrue(wrapperPlist.contains("dev.tuist.App2.NotificationServiceExtension"))
        let appIntentPlist = try XCTUnwrap(rendered[".bazel/InfoPlists/AppIntentExtension-Info.plist"])
        XCTAssertTrue(appIntentPlist.contains("com.apple.appintents-extension"))
    }

    private func firstRule(named name: String, in buildFile: String) -> String? {
        buildFile.components(separatedBy: "\n\n").first { block in
            block.contains("name = \"\(name)\"")
        }
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
