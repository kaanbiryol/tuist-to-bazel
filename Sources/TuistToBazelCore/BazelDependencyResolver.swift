import Foundation

struct BazelDependencyResolver {
    typealias ApplePlatform = BazelGenerator.ApplePlatform
    typealias ResolvedDependencies = BazelGenerator.ResolvedDependencies

    let graph: TuistGraph
    let paths: PathContext
    let resourceAccessors: ResourceAccessorGenerator
    let targetsByName: [String: TuistTarget]
    let targetsByPathAndName: [String: TuistTarget]
    let remoteSwiftPackageProductLabelsByProjectPath: [String: [String: BazelLabel]]
    var warnings: [String] = []

    mutating func resolvedDependencies(for target: TuistTarget, packagePath: String) throws -> ResolvedDependencies {
        var result = ResolvedDependencies()
        let targetPlatform = platform(for: target)

        for dependency in target.dependencies {
            guard dependencyIsActive(dependency, for: targetPlatform) else {
                continue
            }
            if let dependencyTarget = resolveTargetDependency(dependency) {
                switch dependencyTarget.product {
                case .macro:
                    result.pluginDeps.append(try productLabel(for: dependencyTarget))
                case .framework where target.product == .app || Self.isExtensionProduct(target.product):
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                    result.frameworkDeps.append(try productLabel(for: dependencyTarget))
                case _ where target.product == .app && Self.isExtensionProduct(dependencyTarget.product):
                    result.extensionDeps.append(try productLabel(for: dependencyTarget))
                case .bundle:
                    if let resource = try resourceLabel(for: dependencyTarget) {
                        result.resourceDeps.append(resource)
                    }
                case .app where target.product == .unitTests || target.product == .uiTests:
                    result.testHost = try productLabel(for: dependencyTarget)
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                default:
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                    result.resourceDeps.append(contentsOf: try staticRuntimeResourceLabels(for: dependencyTarget))
                }
                continue
            }

            switch dependency {
            case let .package(product, kind, url, _):
                let label = url.map {
                    BazelLabel(package: "@\(remoteSwiftPackageRepositoryName(for: $0))", name: product)
                } ?? remoteSwiftPackageProductLabelsByProjectPath[target.projectPath]?[product]
                if let label {
                    switch kind {
                    case .runtime:
                        result.codeDeps.append(label)
                    case .plugin:
                        result.pluginDeps.append(label)
                    }
                } else {
                    warnings.append("package dependency \(product) on target \(target.name) is not generated yet")
                }
            case let .sdk(name, status):
                result.linkopts.append(contentsOf: sdkLinkopts(for: name, status: status))
            case let .xcframework(path):
                result.codeDeps.append(BazelLabel(
                    package: binaryImportPackage(for: path, consumingPackage: packagePath),
                    name: BazelBinaryImportRenderer.name(for: path)
                ))
            case .xctest:
                result.includeDeveloperSearchPaths = true
                result.linkopts.append(contentsOf: ["-framework", "XCTest"])
            case .target, .project:
                warnings.append("unresolved target dependency on \(target.name)")
            case let .unsupported(description):
                warnings.append("unsupported dependency on \(target.name): \(description)")
            }
        }

        if importsXCTestUnconditionally(in: target.sources), !result.includeDeveloperSearchPaths {
            result.includeDeveloperSearchPaths = true
            result.linkopts.append(contentsOf: ["-framework", "XCTest"])
        }

        result.codeDeps.append(contentsOf: try binaryImportDepsReferencedBySources(for: target, packagePath: packagePath))
        result.codeDeps = Array(Set(result.codeDeps)).sorted()
        result.pluginDeps = Array(Set(result.pluginDeps)).sorted()
        result.frameworkDeps = Array(Set(result.frameworkDeps)).sorted()
        result.extensionDeps = Array(Set(result.extensionDeps)).sorted()
        result.resourceDeps = Array(Set(result.resourceDeps)).sorted()
        result.linkopts = orderedUnique(result.linkopts)
        return result
    }

    func staticRuntimeResourceLabels(for target: TuistTarget) throws -> [BazelLabel] {
        var visited: Set<String> = []
        return try staticRuntimeResourceLabels(for: target, visited: &visited)
    }

    private func staticRuntimeResourceLabels(
        for target: TuistTarget,
        visited: inout Set<String>
    ) throws -> [BazelLabel] {
        guard visited.insert(Self.targetIdentity(target)).inserted else {
            return []
        }

        var labels: [BazelLabel] = []
        switch target.product {
        case .bundle:
            if let resource = try resourceLabel(for: target) {
                labels.append(resource)
            }
        case .staticFramework, .staticLibrary, .dynamicLibrary:
            if let resource = try resourceLabel(for: target) {
                labels.append(resource)
            }
            let targetPlatform = platform(for: target)
            for dependency in target.dependencies where dependencyIsActive(dependency, for: targetPlatform) {
                guard let dependencyTarget = resolveTargetDependency(dependency) else {
                    continue
                }
                labels.append(contentsOf: try staticRuntimeResourceLabels(for: dependencyTarget, visited: &visited))
            }
        case .app, .appExtension, .framework, .macro, .unitTests, .uiTests, .unsupported:
            break
        }

        return Array(Set(labels)).sorted()
    }

    func importsXCTestUnconditionally(in sourcePaths: [String]) -> Bool {
        sourcePaths.contains { path in
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            return Self.importsXCTestUnconditionally(inContent: content)
        }
    }

    static func importsXCTestUnconditionally(inContent content: String) -> Bool {
        var conditionalDepth = 0
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#if") || line.hasPrefix("#elseif") || line.hasPrefix("#else") {
                if line.hasPrefix("#if") {
                    conditionalDepth += 1
                }
                continue
            }
            if line.hasPrefix("#endif") {
                conditionalDepth = max(0, conditionalDepth - 1)
                continue
            }
            if conditionalDepth == 0,
               line.range(of: #"^(?:@_exported\s+)?import\s+XCTest(?:\s|$)"#, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    func binaryImportDepsReferencedBySources(for target: TuistTarget, packagePath: String) throws -> [BazelLabel] {
        let imports = importedModuleNames(in: target.sources)
        guard !imports.isEmpty else {
            return []
        }

        let binaryImportsByModule = Dictionary(
            grouping: try graph.projects
                .flatMap(\.targets)
                .flatMap(\.dependencies)
                .compactMap { dependency -> (module: String, label: BazelLabel)? in
                    guard case let .xcframework(path) = dependency else {
                        return nil
                    }
                    let xcframework = try BazelXCFrameworkImport(path: path)
                    return (
                        xcframework.name,
                        BazelLabel(
                            package: binaryImportPackage(for: path, consumingPackage: packagePath),
                            name: xcframework.importName
                        )
                    )
                },
            by: \.module
        ).compactMapValues(\.first?.label)

        return imports.compactMap { binaryImportsByModule[$0] }.sorted()
    }

    func importedModuleNames(in sourcePaths: [String]) -> Set<String> {
        sourcePaths.reduce(into: Set<String>()) { result, path in
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return
            }
            result.formUnion(Self.captures(pattern: #"(?m)^\s*(?:@_exported\s+)?import\s+(?:(?:class|struct|enum|protocol|func|var|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)"#, in: content))
        }
    }

    static func captures(pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let matchRange = Range(match.range(at: 1), in: value) else {
                return nil
            }
            return String(value[matchRange])
        }
    }

    static func isExtensionProduct(_ product: ProductType) -> Bool {
        switch product {
        case .appExtension:
            true
        case .app, .framework, .staticFramework, .staticLibrary, .dynamicLibrary, .macro, .bundle, .unitTests, .uiTests, .unsupported:
            false
        }
    }

    func resolveTargetDependency(_ dependency: TuistDependency) -> TuistTarget? {
        switch dependency {
        case let .target(name, _):
            targetsByName[name]
        case let .project(target, path, _):
            targetsByPathAndName[Self.indexKey(path: path, name: target)] ?? targetsByName[target]
        case .xcframework, .package, .sdk, .xctest, .unsupported:
            nil
        }
    }

    func dependencyIsActive(_ dependency: TuistDependency, for platform: ApplePlatform) -> Bool {
        guard let condition = Self.dependencyCondition(dependency) else {
            return true
        }
        return condition.platformFilters.contains(platform.dependencyConditionName)
    }

    static func dependencyCondition(_ dependency: TuistDependency) -> TuistDependencyCondition? {
        switch dependency {
        case let .target(_, condition):
            condition
        case let .project(_, _, condition):
            condition
        case let .package(_, _, _, condition):
            condition
        case .xcframework, .sdk, .xctest, .unsupported:
            nil
        }
    }

    func sdkLinkopts(for name: String, status: String?) -> [String] {
        if name.hasSuffix(".framework") {
            let framework = String(name.dropLast(".framework".count))
            if status == "optional" {
                return ["-Wl,-weak_framework,\(framework)"]
            }
            return ["-framework", framework]
        }

        if name.hasSuffix(".tbd") {
            let library = String(name.dropLast(".tbd".count))
            let linkerName = library.hasPrefix("lib") ? String(library.dropFirst(3)) : library
            return ["-l\(linkerName)"]
        }

        return ["-framework", name]
    }

    func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    func binaryImportPackage(for path: String, consumingPackage: String) -> String {
        BazelBinaryImportRenderer.package(for: path, consumingPackage: consumingPackage, paths: paths)
    }

    func productLabel(for target: TuistTarget) throws -> BazelLabel {
        BazelLabel(package: try paths.packagePath(for: target.projectPath), name: target.name)
    }

    func hasSwiftLibrary(for target: TuistTarget) -> Bool {
        target.product.isSwiftBacked && (
            target.sources.contains { $0.hasSuffix(".swift") } ||
            resourceAccessors.shouldGenerate(for: target)
        )
    }

    func libraryLabel(for target: TuistTarget) throws -> BazelLabel? {
        guard hasSwiftLibrary(for: target) else { return nil }
        return BazelLabel(package: try paths.packagePath(for: target.projectPath), name: Self.libraryName(for: target))
    }

    func resourceLabel(for target: TuistTarget) throws -> BazelLabel? {
        if target.product == .bundle {
            return try productLabel(for: target)
        }
        guard !target.resources.isEmpty else { return nil }
        return BazelLabel(package: try paths.packagePath(for: target.projectPath), name: "_\(target.name)Resources")
    }

    func defaultBundleId(for target: TuistTarget) -> String {
        Self.defaultBundleId(for: target)
    }

    func platform(for target: TuistTarget) -> ApplePlatform {
        BazelGenerator.resolvePlatform(for: target)
    }

    static func libraryName(for target: TuistTarget) -> String {
        switch target.product {
        case .app, .appExtension, .framework, .staticFramework, .unitTests, .uiTests:
            "\(target.name)Lib"
        case .staticLibrary, .dynamicLibrary, .macro, .bundle, .unsupported:
            target.name
        }
    }

    static func defaultBundleId(for target: TuistTarget) -> String {
        "dev.tuist.\(sanitizedModuleName(target.name))"
    }

    static func indexKey(path: String, name: String) -> String {
        "\(URL(fileURLWithPath: path).standardizedFileURL.path)#\(name)"
    }

    static func targetIdentity(_ target: TuistTarget) -> String {
        indexKey(path: target.projectPath, name: target.name)
    }
}
