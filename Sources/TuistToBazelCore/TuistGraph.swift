import Foundation

struct TuistGraph {
    let name: String
    let projects: [TuistProject]
    var localSwiftPackages: [TuistLocalSwiftPackage] = []
    var remoteSwiftPackages: [TuistRemoteSwiftPackage] = []
}

struct TuistProject {
    let name: String
    let path: String
    let targets: [TuistTarget]
}

struct TuistLocalSwiftPackage: Hashable {
    let path: String
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
    let sources: [String]
    var headers: TuistHeaders = .empty
    var coreDataModels: [TuistCoreDataModel] = []
    let resources: [TuistResource]
    let dependencies: [TuistDependency]
}

struct TuistCoreDataModel: Hashable {
    let path: String
    let currentVersion: String?
    let versions: [String]
}

enum PlistValue: Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case array([PlistValue])
    case dictionary([String: PlistValue])
}

struct TuistHeaders {
    let publicHeaders: [String]
    let privateHeaders: [String]
    let projectHeaders: [String]

    static let empty = TuistHeaders(publicHeaders: [], privateHeaders: [], projectHeaders: [])

    var all: [String] {
        publicHeaders + privateHeaders + projectHeaders
    }
}

enum ProductType: String {
    case app
    case appClip
    case appExtension
    case extensionKitExtension
    case framework
    case messagesExtension
    case staticFramework
    case stickerPackExtension
    case tvTopShelfExtension
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
        case "app_clip", "appClip":
            self = .appClip
        case "app_extension", "appExtension":
            self = .appExtension
        case "extension_kit_extension", "extensionKitExtension":
            self = .extensionKitExtension
        case "framework":
            self = .framework
        case "messages_extension", "messagesExtension":
            self = .messagesExtension
        case "staticFramework", "static_framework":
            self = .staticFramework
        case "sticker_pack_extension", "stickerPackExtension":
            self = .stickerPackExtension
        case "tv_top_shelf_extension", "tvTopShelfExtension":
            self = .tvTopShelfExtension
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
        case .app, .appClip, .appExtension, .extensionKitExtension, .framework, .messagesExtension, .staticFramework, .tvTopShelfExtension, .staticLibrary, .dynamicLibrary, .unitTests, .uiTests:
            true
        case .bundle, .macro, .stickerPackExtension, .unsupported:
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
    case framework(path: String)
    case xcframework(path: String)
    case library(path: String, publicHeaders: String?, swiftModuleMap: String?)
    case package(product: String, kind: PackageDependencyKind = .runtime)
    case sdk(name: String, status: String?)
    case xctest
}

struct TuistDependencyCondition: Equatable {
    let platformFilters: [String]
}

enum PackageDependencyKind: Equatable {
    case runtime
    case plugin
}
