import Foundation

struct TuistGraph {
    let name: String
    var projects: [TuistProject]
    var localSwiftPackagePaths: [String] = []
    var remoteSwiftPackages: [TuistRemoteSwiftPackage] = []
    var remoteSwiftPackagesByProjectPath: [String: [TuistRemoteSwiftPackage]] = [:]
}

struct TuistProject {
    let name: String
    let path: String
    var targets: [TuistTarget]
}

struct TuistRemoteSwiftPackage: Hashable {
    let url: String
    let requirement: SwiftPackageRequirement
}

enum SwiftPackageRequirement: Hashable {
    case upToNextMajor(String)
    case upToNextMinor(String)
    case exact(String)
    case branch(String)
    case revision(String)

    var packageDescriptionExpression: String {
        switch self {
        case let .upToNextMajor(version):
            ".upToNextMajor(from: \(Starlark.quote(version)))"
        case let .upToNextMinor(version):
            ".upToNextMinor(from: \(Starlark.quote(version)))"
        case let .exact(version):
            ".exact(\(Starlark.quote(version)))"
        case let .branch(branch):
            ".branch(\(Starlark.quote(branch)))"
        case let .revision(revision):
            ".revision(\(Starlark.quote(revision)))"
        }
    }
}

struct TuistTarget {
    let name: String
    let product: ProductType
    var destinations: [String] = []
    let bundleId: String?
    let productName: String
    let projectPath: String
    let infoPlistPath: String?
    var infoPlistEntries: [String: PlistValue] = [:]
    let swiftVersion: String?
    let sources: [String]
    var headers: [String] = []
    var coreDataModelPaths: [String] = []
    let resources: [TuistResource]
    var dependencies: [TuistDependency]

    var swiftLanguageMode: String? {
        guard let swiftVersion, !swiftVersion.isEmpty else { return nil }
        if swiftVersion == "4.2" {
            return swiftVersion
        }

        // Xcode accepts SDK-version-shaped values such as 5.9 and 6.1 for
        // SWIFT_VERSION, but swiftc's language-mode flag accepts only the major
        // compatibility version (apart from the distinct Swift 4.2 mode).
        return swiftVersion.split(separator: ".", maxSplits: 1).first.map(String.init)
    }
}

enum PlistValue: Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([PlistValue])
    case dictionary([String: PlistValue])
}

enum ProductType: String {
    case app
    case appExtension
    case framework
    case staticFramework
    case staticLibrary
    case dynamicLibrary
    case macro
    case bundle
    case unitTests
    case uiTests
    case unsupported

    init(rawGraphValue: String) {
        switch rawGraphValue {
        case "app":
            self = .app
        case "app_extension", "appExtension":
            self = .appExtension
        case "framework":
            self = .framework
        case "staticFramework", "static_framework":
            self = .staticFramework
        case "staticLibrary", "static_library":
            self = .staticLibrary
        case "dynamicLibrary", "dynamic_library":
            self = .dynamicLibrary
        case "macro":
            self = .macro
        case "bundle":
            self = .bundle
        case "unitTests", "unit_tests":
            self = .unitTests
        case "uiTests", "ui_tests":
            self = .uiTests
        default:
            self = .unsupported
        }
    }

    var isSwiftBacked: Bool {
        switch self {
        case .app, .appExtension, .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .unitTests, .uiTests:
            true
        case .bundle, .macro, .unsupported:
            false
        }
    }
}

struct TuistResource: Hashable {
    enum Kind {
        case file
        case folderReference
    }

    let path: String
    let kind: Kind
    let tags: [String]
}

enum TuistDependency {
    case target(name: String, condition: TuistDependencyCondition? = nil)
    case project(target: String, path: String, condition: TuistDependencyCondition? = nil)
    case xcframework(path: String)
    case package(
        product: String,
        kind: PackageDependencyKind = .runtime,
        url: String? = nil,
        condition: TuistDependencyCondition? = nil
    )
    case sdk(name: String, status: String?)
    case xctest
    case unsupported(String)
}

struct TuistDependencyCondition: Equatable {
    let platformFilters: [String]
}

enum PackageDependencyKind: Equatable {
    case runtime
    case plugin
}
