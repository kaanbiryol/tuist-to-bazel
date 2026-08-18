import XCTest
@testable import TuistToBazelCore

final class BazelGeneratorTests: XCTestCase {
    func testGeneratesRetainedIOSAndMacOSProducts() throws {
        let root = URL(fileURLWithPath: "/tmp/RetainedProductsFixture")
        let targets = [
            makeTarget(
                "App",
                product: .app,
                root: root,
                dependencies: [
                    .target(name: "Framework"),
                    .target(name: "AppExtension"),
                    .target(name: "DynamicLibrary"),
                ]
            ),
            makeTarget(
                "AppExtension",
                product: .appExtension,
                root: root,
                bundleId: "dev.tuist.App.extension",
                dependencies: [.target(name: "Framework")]
            ),
            makeTarget("AppTests", product: .unitTests, root: root, dependencies: [.target(name: "App")]),
            makeTarget("AppUITests", product: .uiTests, root: root, dependencies: [.target(name: "App")]),
            makeTarget("Framework", product: .framework, root: root),
            makeTarget(
                "StaticFramework",
                product: .staticFramework,
                root: root,
                dependencies: [.target(name: "Framework")]
            ),
            makeTarget("StaticLibrary", product: .staticLibrary, root: root),
            makeTarget(
                "DynamicLibrary",
                product: .dynamicLibrary,
                root: root,
                destinations: ["iPhone", "appleTv"]
            ),
            makeTarget("MacApp", product: .app, root: root, destinations: ["mac"], dependencies: [.target(name: "MacFramework")]),
            makeTarget("MacFramework", product: .framework, root: root, destinations: ["mac"]),
        ]
        let graph = graph(named: "RetainedProductsFixture", root: root, targets: targets)

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let build = try XCTUnwrap(try generator.render().files["BUILD.bazel"])

        XCTAssertTrue(build.contains("ios_application(\n    name = \"App\""))
        XCTAssertTrue(build.contains("macos_application(\n    name = \"MacApp\""))
        XCTAssertTrue(build.contains("ios_extension(\n    name = \"AppExtension\""))
        XCTAssertTrue(build.contains("ios_framework(\n    name = \"Framework\""))
        XCTAssertTrue(build.contains("macos_framework(\n    name = \"MacFramework\""))
        XCTAssertTrue(build.contains("ios_static_framework(\n    name = \"StaticFramework\""))
        XCTAssertTrue(build.contains("swift_library(\n    name = \"StaticLibrary\""))
        XCTAssertTrue(build.contains("swift_library(\n    name = \"DynamicLibrary\""))
        XCTAssertTrue(build.contains("ios_unit_test(\n    name = \"AppTests\""))
        XCTAssertTrue(build.contains("ios_ui_test(\n    name = \"AppUITests\""))
        XCTAssertTrue(build.contains("ios_test_runner(\n    name = \"_ios_test_runner\""))
        XCTAssertTrue(build.contains("test_host = \":App\""))
        XCTAssertTrue(build.contains("extension_safe = True"))
        XCTAssertTrue(build.contains("minimum_os_version = \"14.0\""))
    }

    func testPropagatesStaticLibraryAndBundleResourcesIntoApp() throws {
        let root = URL(fileURLWithPath: "/tmp/StaticResourcesFixture")
        let image = root.appendingPathComponent("Resources/image.png").path
        let targets = [
            makeTarget("App", product: .app, root: root, dependencies: [.target(name: "StaticLibrary")]),
            makeTarget(
                "StaticLibrary",
                product: .staticLibrary,
                root: root,
                dependencies: [.target(name: "ResourceBundle")]
            ),
            makeTarget(
                "ResourceBundle",
                product: .bundle,
                root: root,
                sources: [],
                resources: [TuistResource(path: image, kind: .file, tags: [])]
            ),
        ]
        let graph = graph(named: "StaticResourcesFixture", root: root, targets: targets)

        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let build = try XCTUnwrap(try generator.render().files["BUILD.bazel"])

        XCTAssertTrue(build.contains("apple_resource_bundle(\n    name = \"ResourceBundle\""))
        XCTAssertTrue(build.contains("resources = [\n        \":ResourceBundle\","))
    }

    func testGeneratesSwiftCompilerPluginsForMacroTargets() throws {
        let root = URL(fileURLWithPath: "/tmp/MacroFixture")
        let targets = [
            makeTarget(
                "Framework",
                product: .framework,
                root: root,
                destinations: ["mac"],
                dependencies: [.target(name: "FrameworkMacros")]
            ),
            makeTarget("FrameworkMacros", product: .macro, root: root, destinations: ["mac"]),
        ]
        var generator = BazelGenerator(
            graph: graph(named: "MacroFixture", root: root, targets: targets),
            paths: PathContext(root: root, output: root)
        )
        let build = try XCTUnwrap(try generator.render().files["BUILD.bazel"])

        XCTAssertTrue(build.contains("swift_compiler_plugin(\n    name = \"FrameworkMacros\""))
        XCTAssertTrue(build.contains("plugins = [\n        \":FrameworkMacros\","))
        XCTAssertTrue(build.contains("macos_framework("))
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
                "state": { "branch": null, "revision": "abc123", "version": "5.0.1" }
              },
              {
                "package": "swift-syntax",
                "repositoryURL": "https://github.com/swiftlang/swift-syntax.git",
                "state": { "branch": null, "revision": "def456", "version": "603.0.2" }
              }
            ]
          },
          "version": 1
        }
        """.write(to: root.appendingPathComponent("Package.resolved"), atomically: true, encoding: .utf8)

        let target = makeTarget(
            "App",
            product: .app,
            root: root,
            dependencies: [
                .package(product: "RxSwift"),
                .package(product: "RxSwiftPlugin", kind: .plugin),
            ]
        )
        let graph = TuistGraph(
            name: "RemoteSPMFixture",
            projects: [TuistProject(name: "App", path: root.path, targets: [target])],
            remoteSwiftPackages: [
                TuistRemoteSwiftPackage(
                    url: "https://github.com/ReactiveX/RxSwift",
                    requirement: .upToNextMajor("5.0.0")
                ),
            ]
        )
        var generator = BazelGenerator(graph: graph, paths: PathContext(root: root, output: root))
        let rendered = try generator.render().files

        XCTAssertTrue(try XCTUnwrap(rendered["BUILD.bazel"]).contains("@swiftpkg_rxswift//:RxSwift"))
        XCTAssertTrue(
            try XCTUnwrap(rendered["BUILD.bazel"])
                .contains("plugins = [\n        \"@swiftpkg_rxswift//:RxSwiftPlugin\",")
        )
        XCTAssertTrue(try XCTUnwrap(rendered["MODULE.bazel"]).contains("\"swiftpkg_rxswift\""))
        XCTAssertTrue(
            try XCTUnwrap(rendered[".bazel/SwiftPackages/Package.swift"])
                .contains(".package(url: \"https://github.com/ReactiveX/RxSwift\", .upToNextMajor(from: \"5.0.0\"))")
        )
        XCTAssertTrue(try XCTUnwrap(rendered[".bazel/SwiftPackages/Package.resolved"]).contains("\"identity\" : \"rxswift\""))
        XCTAssertTrue(
            try XCTUnwrap(rendered[".bazel/SwiftPackages/Package.resolved"])
                .contains("\"identity\" : \"swift-syntax\"")
        )
        XCTAssertFalse(
            try XCTUnwrap(rendered[".bazel/SwiftPackages/Package.resolved"])
                .contains("\"identity\" : \"swift_syntax\"")
        )
    }

    func testGeneratesStaticAndDynamicXCFrameworkImports() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-xcframework-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let dynamic = root.appendingPathComponent("Vendor/MyFramework.xcframework", isDirectory: true)
        let `static` = root.appendingPathComponent("Vendor/MyStaticLibrary.xcframework", isDirectory: true)
        try writeXCFrameworkInfo(at: dynamic, libraryPath: "MyFramework.framework")
        try writeXCFrameworkInfo(at: `static`, libraryPath: "libMyStaticLibrary.a")
        let staticModule = `static`.appendingPathComponent(
            "ios-arm64_x86_64-simulator/MyStaticLibrary.swiftmodule",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staticModule, withIntermediateDirectories: true)
        try Data().write(to: staticModule.appendingPathComponent("arm64-apple-ios-simulator.swiftinterface"))

        let target = makeTarget(
            "App",
            product: .app,
            root: root,
            dependencies: [.xcframework(path: dynamic.path), .xcframework(path: `static`.path)]
        )
        var generator = BazelGenerator(
            graph: graph(named: "XCFrameworkFixture", root: root, targets: [target]),
            paths: PathContext(root: root, output: root)
        )
        let build = try XCTUnwrap(try generator.render().files["BUILD.bazel"])

        XCTAssertTrue(build.contains("apple_dynamic_xcframework_import("))
        XCTAssertTrue(build.contains("name = \"_MyFrameworkImport\""))
        XCTAssertTrue(build.contains("apple_static_xcframework_import("))
        XCTAssertTrue(build.contains("name = \"_MyStaticLibraryImport\""))
        XCTAssertTrue(build.contains("apple._import_framework_via_swiftinterface"))
    }

    func testAddsXCFrameworkDependencyWhenAnotherTargetImportsItsModule() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-xcframework-import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let xcframework = root.appendingPathComponent("Vendor/MyFramework.xcframework", isDirectory: true)
        try writeXCFrameworkInfo(at: xcframework, libraryPath: "MyFramework.framework")
        let appSource = root.appendingPathComponent("App.swift")
        let frameworkSource = root.appendingPathComponent("Framework.swift")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try "import MyFramework\nstruct AppType {}\n".write(to: appSource, atomically: true, encoding: .utf8)
        try "import MyFramework\npublic struct FrameworkType {}\n".write(to: frameworkSource, atomically: true, encoding: .utf8)

        let targets = [
            makeTarget("App", product: .app, root: root, sources: [appSource.path], dependencies: [.target(name: "Framework")]),
            makeTarget(
                "Framework",
                product: .framework,
                root: root,
                sources: [frameworkSource.path],
                dependencies: [.xcframework(path: xcframework.path)]
            ),
        ]
        var generator = BazelGenerator(
            graph: graph(named: "XCFrameworkImportFixture", root: root, targets: targets),
            paths: PathContext(root: root, output: root)
        )
        let build = try XCTUnwrap(try generator.render().files["BUILD.bazel"])
        let appLibrary = try XCTUnwrap(firstRule(named: "AppLib", in: build))

        XCTAssertTrue(appLibrary.contains(":_MyFrameworkImport"))
    }

    func testGeneratesSDKLinkOptionsForSwiftTargets() throws {
        let root = URL(fileURLWithPath: "/tmp/SDKFixture")
        let target = makeTarget(
            "Framework",
            product: .framework,
            root: root,
            dependencies: [
                .sdk(name: "CloudKit.framework", status: "optional"),
                .sdk(name: "libsqlite3.tbd", status: "required"),
                .xctest,
            ]
        )
        var generator = BazelGenerator(
            graph: graph(named: "SDKFixture", root: root, targets: [target]),
            paths: PathContext(root: root, output: root)
        )
        let build = try XCTUnwrap(try generator.render().files["BUILD.bazel"])

        XCTAssertTrue(build.contains("\"-Wl,-weak_framework,CloudKit\""))
        XCTAssertTrue(build.contains("\"-lsqlite3\""))
        XCTAssertTrue(build.contains("always_include_developer_search_paths = True"))
        XCTAssertTrue(build.contains("\"-framework\""))
        XCTAssertTrue(build.contains("\"XCTest\""))
    }

    func testFiltersDependenciesBetweenIOSAndMacOS() throws {
        let root = URL(fileURLWithPath: "/tmp/PlatformFilterFixture")
        let targets = [
            makeTarget(
                "App",
                product: .app,
                root: root,
                dependencies: [
                    .target(name: "IOSFramework", condition: TuistDependencyCondition(platformFilters: ["ios"])),
                    .target(name: "MacFramework", condition: TuistDependencyCondition(platformFilters: ["macos"])),
                ]
            ),
            makeTarget(
                "MacApp",
                product: .app,
                root: root,
                destinations: ["mac"],
                dependencies: [
                    .target(name: "IOSFramework", condition: TuistDependencyCondition(platformFilters: ["ios"])),
                    .target(name: "MacFramework", condition: TuistDependencyCondition(platformFilters: ["macos"])),
                ]
            ),
            makeTarget("IOSFramework", product: .framework, root: root),
            makeTarget("MacFramework", product: .framework, root: root, destinations: ["mac"]),
        ]
        var generator = BazelGenerator(
            graph: graph(named: "PlatformFilterFixture", root: root, targets: targets),
            paths: PathContext(root: root, output: root)
        )
        let build = try XCTUnwrap(try generator.render().files["BUILD.bazel"])
        let iosLibrary = try XCTUnwrap(firstRule(named: "AppLib", in: build))
        let macLibrary = try XCTUnwrap(firstRule(named: "MacAppLib", in: build))

        XCTAssertTrue(iosLibrary.contains(":IOSFrameworkLib"))
        XCTAssertFalse(iosLibrary.contains(":MacFrameworkLib"))
        XCTAssertFalse(macLibrary.contains(":IOSFrameworkLib"))
        XCTAssertTrue(macLibrary.contains(":MacFrameworkLib"))
    }

    func testGeneratesBundleModuleAccessorForResources() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-resources-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let source = root.appendingPathComponent("Sources/Provider.swift")
        let assets = root.appendingPathComponent("Resources/Assets.xcassets/logo.imageset", isDirectory: true)
        try fileManager.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
        try "import Foundation\nenum Provider { static let bundle: Bundle = .module }\n".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        try #"{"images":[],"info":{"author":"xcode","version":1}}"#.write(
            to: assets.appendingPathComponent("Contents.json"),
            atomically: true,
            encoding: .utf8
        )

        let target = makeTarget(
            "Framework",
            product: .framework,
            root: root,
            sources: [source.path],
            resources: [
                TuistResource(
                    path: root.appendingPathComponent("Resources/Assets.xcassets").path,
                    kind: .file,
                    tags: []
                ),
            ]
        )
        var generator = BazelGenerator(
            graph: graph(named: "ResourcesFixture", root: root, targets: [target]),
            paths: PathContext(root: root, output: root)
        )
        let rendered = try generator.render().files
        let accessor = try XCTUnwrap(rendered[".bazel/Generated/FrameworkResourceAccessors.swift"])

        XCTAssertTrue(try XCTUnwrap(rendered["BUILD.bazel"]).contains(".bazel/Generated/FrameworkResourceAccessors.swift"))
        XCTAssertTrue(accessor.contains("static var module: Bundle"))
    }

    func testGeneratedExtensionInfoPlistInheritsHostVersions() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("tuist-to-bazel-extension-versions-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let appPlist = root.appendingPathComponent("App-Info.plist")
        try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleVersion": "7", "CFBundleShortVersionString": "3.2"],
            format: .xml,
            options: 0
        ).write(to: appPlist)

        let targets = [
            makeTarget(
                "App",
                product: .app,
                root: root,
                infoPlistPath: appPlist.path,
                dependencies: [.target(name: "NotificationExtension")]
            ),
            makeTarget(
                "NotificationExtension",
                product: .appExtension,
                root: root,
                bundleId: "dev.tuist.App.NotificationExtension",
                infoPlistEntries: [
                    "NSExtension": .dictionary([
                        "NSExtensionPointIdentifier": .string("com.apple.usernotifications.service"),
                    ]),
                ]
            ),
        ]
        var generator = BazelGenerator(
            graph: graph(named: "ExtensionFixture", root: root, targets: targets),
            paths: PathContext(root: root, output: root)
        )
        let rendered = try generator.render().files
        let plist = try XCTUnwrap(rendered[".bazel/InfoPlists/NotificationExtension-Info.plist"])

        XCTAssertTrue(plist.contains("<key>CFBundleVersion</key>\n\t<string>7</string>"))
        XCTAssertTrue(plist.contains("<key>CFBundleShortVersionString</key>\n\t<string>3.2</string>"))
        XCTAssertTrue(try XCTUnwrap(rendered["BUILD.bazel"]).contains("ios_extension("))
    }

    func testRejectsRemovedFeaturesBeforeRendering() throws {
        let root = URL(fileURLWithPath: "/tmp/UnsupportedFixture")
        let cases: [(target: TuistTarget, message: String)] = [
            (makeTarget("AppClip", product: .unsupported, root: root), "unsupported product"),
            (makeTarget("WatchApp", product: .app, root: root, destinations: ["appleWatch"]), "unsupported destination"),
            (
                makeTarget("Mixed", product: .framework, root: root, sources: [root.appendingPathComponent("Mixed.m").path]),
                "non-Swift source"
            ),
            (
                makeTarget("Headers", product: .framework, root: root, headers: [root.appendingPathComponent("Public.h").path]),
                "contains header"
            ),
            (
                makeTarget(
                    "CoreData",
                    product: .app,
                    root: root,
                    coreDataModelPaths: [root.appendingPathComponent("Users.xcdatamodeld").path]
                ),
                "Core Data generation is not supported"
            ),
            (
                makeTarget(
                    "LegacyBinary",
                    product: .app,
                    root: root,
                    dependencies: [.unsupported("checked-in framework at Vendor/Legacy.framework")]
                ),
                "use an XCFramework instead"
            ),
        ]

        for testCase in cases {
            var generator = BazelGenerator(
                graph: graph(named: "UnsupportedFixture", root: root, targets: [testCase.target]),
                paths: PathContext(root: root, output: root)
            )
            XCTAssertThrowsError(try generator.render()) { error in
                XCTAssertTrue(String(describing: error).contains(testCase.message))
            }
        }

        var localPackageGenerator = BazelGenerator(
            graph: TuistGraph(
                name: "LocalPackageFixture",
                projects: [TuistProject(name: "App", path: root.path, targets: [])],
                localSwiftPackagePaths: [root.appendingPathComponent("Packages/Local").path]
            ),
            paths: PathContext(root: root, output: root)
        )
        XCTAssertThrowsError(try localPackageGenerator.render()) { error in
            XCTAssertTrue(String(describing: error).contains("local Swift package conversion is not supported"))
        }
    }

    private func graph(named name: String, root: URL, targets: [TuistTarget]) -> TuistGraph {
        TuistGraph(
            name: name,
            projects: [TuistProject(name: name, path: root.path, targets: targets)]
        )
    }

    private func makeTarget(
        _ name: String,
        product: ProductType,
        root: URL,
        destinations: [String] = ["iPhone", "iPad"],
        bundleId: String? = nil,
        infoPlistPath: String? = nil,
        infoPlistEntries: [String: PlistValue] = [:],
        sources: [String]? = nil,
        headers: [String] = [],
        coreDataModelPaths: [String] = [],
        resources: [TuistResource] = [],
        dependencies: [TuistDependency] = []
    ) -> TuistTarget {
        TuistTarget(
            name: name,
            product: product,
            destinations: destinations,
            bundleId: bundleId ?? "dev.tuist.\(name)",
            productName: name,
            projectPath: root.path,
            infoPlistPath: infoPlistPath,
            infoPlistEntries: infoPlistEntries,
            sources: sources ?? [root.appendingPathComponent("Sources/\(name).swift").path],
            headers: headers,
            coreDataModelPaths: coreDataModelPaths,
            resources: resources,
            dependencies: dependencies
        )
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
