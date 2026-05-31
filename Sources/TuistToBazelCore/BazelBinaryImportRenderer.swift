import Foundation

struct BazelBinaryImportRenderer {
    let graph: TuistGraph
    let paths: PathContext

    func render(packagePath: String, targets: [TuistTarget]) throws -> [String] {
        let dependencyPairs = try dependenciesWithConsumingPackages(for: packagePath, targets: targets)
        let frameworkPaths = Set(dependencyPairs.flatMap { pair in
            pair.dependencies.compactMap { dependency -> String? in
                if case let .framework(path) = dependency,
                   Self.package(for: path, consumingPackage: pair.packagePath, paths: paths) == packagePath {
                    return path
                }
                return nil
            }
        })
        let libraryImports = Dictionary(
            grouping: dependencyPairs.flatMap { pair in
                pair.dependencies.compactMap { dependency -> BazelLibraryImport? in
                    if case let .library(path, _, swiftModuleMap) = dependency,
                       let swiftModuleMap,
                       Self.package(for: dependency, consumingPackage: pair.packagePath, paths: paths) == packagePath {
                        return BazelLibraryImport(path: path, swiftModuleMap: swiftModuleMap)
                    }
                    return nil
                }
            },
            by: \.name
        ).values.compactMap(\.first)
        let xcframeworkImports = Dictionary(
            grouping: try dependencyPairs.flatMap { pair in
                try pair.dependencies.compactMap { dependency -> BazelXCFrameworkImport? in
                    if case let .xcframework(path) = dependency,
                       Self.package(for: path, consumingPackage: pair.packagePath, paths: paths) == packagePath {
                        return try BazelXCFrameworkImport(path: path)
                    }
                    return nil
                }
            },
            by: \.name
        ).values.compactMap(\.first)

        let frameworkImports = try frameworkPaths.sorted().map { path in
            let relative = try paths.pathRelativeToPackage(path, packagePath: packagePath)
            return """
            apple_static_framework_import(
                name = "\(Self.name(for: path))",
                framework_imports = glob([\(Starlark.quote(relative + "/**"))]),
                tags = ["manual"],
            )
            """
        }
        let xcframeworkRules = try xcframeworkImports.sorted(by: { $0.name < $1.name }).map { xcframeworkImport in
            let relative = try paths.pathRelativeToPackage(xcframeworkImport.path, packagePath: packagePath)
            let featuresAttribute = xcframeworkImport.features.isEmpty ? "" : "    features = \(Starlark.list(xcframeworkImport.features, indent: 4)),\n"
            return """
            \(xcframeworkImport.ruleName)(
                name = "\(xcframeworkImport.importName)",
            \(featuresAttribute)    tags = ["manual"],
                xcframework_imports = glob([\(Starlark.quote(relative + "/**"))]),
            )
            """
        }
        let swiftImports = try libraryImports.sorted(by: { $0.name < $1.name }).map { libraryImport in
            let archive = try paths.pathRelativeToPackage(libraryImport.path, packagePath: packagePath)
            let swiftInterface = try paths.pathRelativeToPackage(libraryImport.swiftInterfacePath, packagePath: packagePath)
            let swiftDoc = try paths.pathRelativeToPackage(libraryImport.swiftDocPath, packagePath: packagePath)
            return """
            swift_import(
                name = "\(libraryImport.importName)",
                archives = [\(Starlark.quote(archive))],
                module_name = "\(libraryImport.name)",
                swiftdoc = \(Starlark.quote(swiftDoc)),
                swiftinterface = \(Starlark.quote(swiftInterface)),
                tags = ["manual"],
            )
            """
        }

        return frameworkImports + xcframeworkRules + swiftImports
    }

    func dependenciesWithConsumingPackages(
        for packagePath: String,
        targets: [TuistTarget]
    ) throws -> [(packagePath: String, dependencies: [TuistDependency])] {
        let dependencyTargets = packagePath.isEmpty ? graph.projects.flatMap(\.targets) : targets
        return try dependencyTargets.map { target in
            (try paths.packagePath(for: target.projectPath), target.dependencies)
        }
    }

    static func package(for dependency: TuistDependency, consumingPackage: String, paths: PathContext) -> String? {
        switch dependency {
        case let .framework(path):
            package(for: path, consumingPackage: consumingPackage, paths: paths)
        case let .xcframework(path):
            package(for: path, consumingPackage: consumingPackage, paths: paths)
        case .library:
            ""
        case .target, .project, .package(_, _), .sdk, .xctest:
            nil
        }
    }

    static func package(for path: String, consumingPackage: String, paths: PathContext) -> String {
        guard let relative = try? paths.pathRelativeToPackage(path, packagePath: consumingPackage),
              relative != "..",
              !relative.hasPrefix("../") else {
            return ""
        }
        return consumingPackage
    }

    static func name(for path: String) -> String {
        "_\(sanitizedModuleName(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent))Import"
    }
}

struct BazelXCFrameworkImport: Hashable {
    enum Kind {
        case dynamic
        case `static`
    }

    let path: String
    let name: String
    let kind: Kind
    let hasSwift: Bool

    init(path: String) throws {
        self.path = path
        self.name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.kind = try Self.kind(at: URL(fileURLWithPath: path))
        self.hasSwift = Self.containsSwiftModule(at: URL(fileURLWithPath: path))
    }

    var importName: String {
        "_\(sanitizedModuleName(name))Import"
    }

    var ruleName: String {
        switch kind {
        case .dynamic:
            "apple_dynamic_xcframework_import"
        case .static:
            "apple_static_xcframework_import"
        }
    }

    var features: [String] {
        guard hasSwift else {
            return []
        }
        switch kind {
        case .dynamic:
            return ["-swift.layering_check"]
        case .static:
            return ["-swift.layering_check", "apple._import_framework_via_swiftinterface"]
        }
    }

    private static func kind(at url: URL) throws -> Kind {
        let infoURL = url.appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let dictionary = plist as? [String: Any],
              let libraries = dictionary["AvailableLibraries"] as? [[String: Any]],
              let libraryPath = libraries.compactMap({ $0["LibraryPath"] as? String }).first else {
            return .dynamic
        }
        return libraryPath.hasSuffix(".a") ? .static : .dynamic
    }

    private static func containsSwiftModule(at url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "swiftmodule" || fileURL.pathExtension == "swiftinterface" {
                return true
            }
        }
        return false
    }
}

struct BazelLibraryImport: Hashable {
    let path: String
    let swiftModuleMap: String

    var name: String {
        URL(fileURLWithPath: swiftModuleMap).deletingPathExtension().lastPathComponent
    }

    var importName: String {
        "_\(sanitizedModuleName(name))Import"
    }

    var swiftInterfacePath: String {
        let moduleDirectory = URL(fileURLWithPath: swiftModuleMap)
        let preferred = moduleDirectory.appendingPathComponent("arm64-apple-ios-simulator.swiftinterface").path
        if FileManager.default.fileExists(atPath: preferred) {
            return preferred
        }
        let fallback = moduleDirectory.appendingPathComponent("x86_64-apple-ios-simulator.swiftinterface").path
        if FileManager.default.fileExists(atPath: fallback) {
            return fallback
        }
        return moduleDirectory.appendingPathComponent("\(name).swiftinterface").path
    }

    var swiftDocPath: String {
        URL(fileURLWithPath: swiftInterfacePath)
            .deletingPathExtension()
            .appendingPathExtension("swiftdoc")
            .path
    }
}
