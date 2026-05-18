import Foundation

struct TuistGraph {
    let name: String
    let projects: [TuistProject]
}

struct TuistProject {
    let name: String
    let path: String
    let targets: [TuistTarget]
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
    let resources: [TuistResource]
    let dependencies: [TuistDependency]
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
    case appExtension
    case extensionKitExtension
    case framework
    case messagesExtension
    case staticFramework
    case stickerPackExtension
    case staticLibrary
    case dynamicLibrary
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
        case "staticLibrary", "static_library":
            self = .staticLibrary
        case "dynamicLibrary", "dynamic_library":
            self = .dynamicLibrary
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
        case .app, .appExtension, .extensionKitExtension, .framework, .messagesExtension, .staticFramework, .staticLibrary, .dynamicLibrary, .unitTests, .uiTests:
            true
        case .bundle, .stickerPackExtension, .unsupported:
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
    case target(name: String)
    case project(target: String, path: String)
    case framework(path: String)
    case xcframework(path: String)
    case library(path: String, publicHeaders: String?, swiftModuleMap: String?)
    case package(product: String)
    case sdk(name: String, status: String?)
    case xctest
}
