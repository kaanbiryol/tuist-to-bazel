import Foundation

extension BazelGenerator {
    func renderBinaryImports(packagePath: String, targets: [TuistTarget]) throws -> [String] {
        let dependencyPairs = try dependenciesWithConsumingPackages(for: packagePath, targets: targets)
        let frameworkPaths = Set(dependencyPairs.flatMap { pair in
            pair.dependencies.compactMap { dependency -> String? in
                if case let .framework(path) = dependency,
                   binaryImportPackage(for: path, consumingPackage: pair.packagePath) == packagePath {
                    return path
                }
                return nil
            }
        })
        let libraryImports = Dictionary(
            grouping: dependencyPairs.flatMap { pair in
                pair.dependencies.compactMap { dependency -> LibraryImport? in
                    if case let .library(path, _, swiftModuleMap) = dependency,
                       let swiftModuleMap,
                       binaryImportPackage(for: dependency, consumingPackage: pair.packagePath) == packagePath {
                        return LibraryImport(path: path, swiftModuleMap: swiftModuleMap)
                    }
                    return nil
                }
            },
            by: \.name
        ).values.compactMap(\.first)
        let xcframeworkImports = Dictionary(
            grouping: try dependencyPairs.flatMap { pair in
                try pair.dependencies.compactMap { dependency -> XCFrameworkImport? in
                    if case let .xcframework(path) = dependency,
                       binaryImportPackage(for: path, consumingPackage: pair.packagePath) == packagePath {
                        return try xcframeworkImport(for: path)
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
                name = "\(binaryImportName(for: path))",
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

    func binaryImportPackage(for dependency: TuistDependency, consumingPackage: String) -> String? {
        switch dependency {
        case let .framework(path):
            binaryImportPackage(for: path, consumingPackage: consumingPackage)
        case let .xcframework(path):
            binaryImportPackage(for: path, consumingPackage: consumingPackage)
        case .library:
            ""
        case .target, .project, .package(_, _), .sdk, .xctest:
            nil
        }
    }

    func binaryImportPackage(for path: String, consumingPackage: String) -> String {
        guard let relative = try? paths.pathRelativeToPackage(path, packagePath: consumingPackage),
              relative != "..",
              !relative.hasPrefix("../") else {
            return ""
        }
        return consumingPackage
    }

}
