import Foundation

struct BazelGenerator {
    private let graph: TuistGraph
    private let paths: PathContext
    private let fileManager = FileManager.default
    private let resourceAccessors = ResourceAccessorGenerator()
    private var warnings: [String] = []
    private var generatedFiles: [String: String] = [:]
    private var targetsByName: [String: TuistTarget] = [:]
    private var targetsByPathAndName: [String: TuistTarget] = [:]
    private var targetsWithTestConsumers: Set<String> = []

    init(graph: TuistGraph, paths: PathContext) {
        self.graph = graph
        self.paths = paths
    }

    mutating func render() throws -> (files: [String: String], warnings: [String]) {
        indexTargets()
        var files: [String: String] = [:]
        files["MODULE.bazel"] = renderModule()
        files["BUILD.bazel"] = try renderRootBuild()

        let targetsByPackage = try Dictionary(grouping: graph.projects.flatMap(\.targets)) { target in
            try paths.packagePath(for: target.projectPath)
        }

        for packagePath in targetsByPackage.keys.sorted() {
            files[pathForBuildFile(packagePath)] = try renderPackageBuild(
                packagePath: packagePath,
                targets: targetsByPackage[packagePath] ?? []
            )
        }
        for (path, content) in generatedFiles {
            files[path] = content
        }

        return (files, warnings)
    }

    private mutating func indexTargets() {
        for target in graph.projects.flatMap(\.targets) {
            targetsByName[target.name] = target
            targetsByPathAndName[indexKey(path: target.projectPath, name: target.name)] = target
        }

        for target in graph.projects.flatMap(\.targets) where target.product == .unitTests || target.product == .uiTests {
            for dependency in target.dependencies {
                if let resolved = resolveTargetDependency(dependency) {
                    targetsWithTestConsumers.insert(resolved.name)
                }
            }
        }
    }

    private func indexKey(path: String, name: String) -> String {
        "\(URL(fileURLWithPath: path).standardizedFileURL.path)#\(name)"
    }

    private func pathForBuildFile(_ packagePath: String) -> String {
        packagePath.isEmpty ? "BUILD.bazel" : "\(packagePath)/BUILD.bazel"
    }

    private func renderModule() -> String {
        """
        bazel_dep(
            name = "rules_xcodeproj",
            version = "4.0.0",
        )
        bazel_dep(
            name = "apple_support",
            version = "2.5.0",
            repo_name = "build_bazel_apple_support",
        )
        bazel_dep(
            name = "rules_apple",
            version = "4.5.2",
            repo_name = "build_bazel_rules_apple",
        )
        bazel_dep(
            name = "rules_swift",
            version = "3.5.0",
            repo_name = "build_bazel_rules_swift",
        )
        bazel_dep(
            name = "rules_ios",
            version = "6.0.1",
            repo_name = "build_bazel_rules_ios",
        )
        bazel_dep(name = "gazelle", version = "0.48.0")
        bazel_dep(name = "rules_swift_package_manager", version = "1.13.0")
        """
    }

    private mutating func renderRootBuild() throws -> String {
        guard let app = graph.projects.flatMap(\.targets).first(where: { $0.product == .app }) else {
            warnings.append("no app target found; root xcodeproj target list is empty")
            return """
            load(
                "@rules_xcodeproj//xcodeproj:defs.bzl",
                "top_level_target",
            )
            load("@rules_xcodeproj//xcodeproj:xcodeproj.bzl", "xcodeproj")

            xcodeproj(
                name = "xcodeproj",
                project_name = "\(sanitizedModuleName(graph.name))",
                scheme_autogeneration_mode = "all",
                top_level_targets = [],
            )
            """
        }

        let appLabel = try productLabel(for: app).description
        return """
        load(
            "@rules_xcodeproj//xcodeproj:defs.bzl",
            "top_level_target",
        )
        load("@rules_xcodeproj//xcodeproj:xcodeproj.bzl", "xcodeproj")

        xcodeproj(
            name = "xcodeproj",
            project_name = "\(sanitizedModuleName(graph.name))",
            scheme_autogeneration_mode = "all",
            top_level_targets = [
                top_level_target(
                    "\(appLabel)",
                    target_environments = ["simulator"],
                ),
            ],
        )
        """
    }

    private mutating func renderPackageBuild(packagePath: String, targets: [TuistTarget]) throws -> String {
        var build = BuildFile()
        let loads = try loadsFor(targets)
        for load in loads {
            build.add(load)
        }
        if !loads.isEmpty {
            build.add()
        }
        build.add("package(default_visibility = [\"//visibility:public\"])")

        for target in targets.sorted(by: { $0.name < $1.name }) {
            build.add()
            build.addBlock(try renderTarget(target, packagePath: packagePath))
        }

        return build.content
    }

    private func loadsFor(_ targets: [TuistTarget]) throws -> [String] {
        var iosRules: Set<String> = []
        var needsSwift = false
        var needsResources = false

        for target in targets {
            needsSwift = needsSwift || target.product.isSwiftBacked
            needsResources = needsResources || !target.resources.isEmpty || target.product == .bundle
            switch target.product {
            case .app:
                iosRules.insert("ios_application")
            case .appExtension:
                iosRules.insert("ios_extension")
            case .framework:
                iosRules.insert("ios_framework")
            case .staticFramework:
                iosRules.insert("ios_static_framework")
            case .unitTests:
                iosRules.insert("ios_unit_test")
            case .uiTests:
                iosRules.insert("ios_ui_test")
            case .staticLibrary, .dynamicLibrary, .bundle, .unsupported:
                break
            }
        }

        var loads: [String] = []
        if needsSwift {
            loads.append("load(\"@build_bazel_rules_swift//swift:swift.bzl\", \"swift_library\")")
        }
        if !iosRules.isEmpty {
            let ruleNames = iosRules.sorted().map(Starlark.quote).joined(separator: ", ")
            loads.append("load(\"@build_bazel_rules_apple//apple:ios.bzl\", \(ruleNames))")
        }
        if needsResources {
            loads.append("load(\"@build_bazel_rules_apple//apple:resources.bzl\", \"apple_bundle_import\", \"apple_resource_bundle\", \"apple_resource_group\")")
        }
        return loads
    }

    private mutating func renderTarget(_ target: TuistTarget, packagePath: String) throws -> String {
        switch target.product {
        case .app:
            return try renderApp(target, packagePath: packagePath)
        case .appExtension:
            return try renderExtension(target, packagePath: packagePath)
        case .framework:
            return try renderFramework(target, packagePath: packagePath)
        case .staticFramework:
            return try renderStaticFramework(target, packagePath: packagePath)
        case .staticLibrary, .dynamicLibrary:
            return try renderSwiftLibrary(target, packagePath: packagePath, name: target.name, testonly: false)
        case .bundle:
            return try renderResourceBundle(target, packagePath: packagePath)
        case .unitTests:
            return try renderUnitTest(target, packagePath: packagePath)
        case .uiTests:
            warnings.append("ui test target \(target.name) is decoded but not generated yet")
            return "# \(target.name) skipped: ui test generation is not implemented yet"
        case .unsupported:
            warnings.append("target \(target.name) has an unsupported product and was skipped")
            return "# \(target.name) skipped: unsupported product"
        }
    }

    private mutating func renderApp(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, extraDeps: deps.codeDeps),
            """
            ios_application(
                name = "\(target.name)",
                bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
                families = ["iphone", "ipad"],
            \(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "17.0",
                deps = [":\(libraryName(for: target))"],
            \(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("extensions", deps.extensionDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderExtension(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, extraDeps: deps.codeDeps),
            """
            ios_extension(
                name = "\(target.name)",
                bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
                families = ["iphone", "ipad"],
            \(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "17.0",
                deps = [":\(libraryName(for: target))"],
            \(optionalLabelListAttribute("frameworks", deps.frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, extraDeps: deps.codeDeps),
            """
            ios_framework(
                name = "\(target.name)",
                bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
                families = ["iphone", "ipad"],
            \(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    minimum_os_version = "17.0",
                deps = [":\(libraryName(for: target))"],
            \(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderStaticFramework(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        var parts: [String] = []
        if let resources = try renderResourceGroupIfNeeded(target, packagePath: packagePath) {
            parts.append(resources)
        }
        if !hasSwiftLibrary(for: target) {
            warnings.append("static framework \(target.name) has no sources; generated its resources but skipped an ios_static_framework wrapper")
            if parts.isEmpty {
                parts.append("# \(target.name) skipped: source-less static framework")
            }
            return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
        }
        parts.append(try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: false, manual: true, extraDeps: deps.codeDeps))

        let frameworkDeps = [BazelLabel(package: packagePath, name: libraryName(for: target))]
        parts.append(
            """
            ios_static_framework(
                name = "\(target.name)",
                minimum_os_version = "17.0",
            \(optionalLabelListAttribute("deps", frameworkDeps, packagePath: packagePath, indent: 4))\(optionalLabelListAttribute("resources", deps.resourceDeps + resourceGroupLabelIfNeeded(target, packagePath: packagePath), packagePath: packagePath, indent: 4)))
            """
        )
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
            .replacingOccurrences(of: ")\n \n", with: ")\n")
    }

    private mutating func renderUnitTest(_ target: TuistTarget, packagePath: String) throws -> String {
        let deps = try resolvedDependencies(for: target, packagePath: packagePath)
        var lines = [
            "ios_unit_test(",
            "    name = \"\(target.name)\",",
            "    bundle_id = \"\(target.bundleId ?? defaultBundleId(for: target))\",",
        ]
        if let infoPlistPath = target.infoPlistPath,
           let relative = try? paths.pathRelativeToPackage(infoPlistPath, packagePath: packagePath) {
            lines.append("    infoplists = [\(Starlark.quote(relative))],")
        }
        lines.append("    minimum_os_version = \"17.0\",")
        lines.append("    deps = [\":\(libraryName(for: target))\"],")
        if let testHost = deps.testHost {
            lines.append("    test_host = \"\(testHost.localDescription(in: packagePath))\",")
            lines.append("    test_host_is_bundle_loader = True,")
        }
        lines.append(")")

        return [
            try renderResourceGroupIfNeeded(target, packagePath: packagePath),
            try renderSwiftLibrary(target, packagePath: packagePath, name: libraryName(for: target), testonly: true, manual: true, extraDeps: deps.codeDeps),
            lines.joined(separator: "\n"),
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private mutating func renderResourceBundle(_ target: TuistTarget, packagePath: String) throws -> String {
        let resources = try resourceExpressions(for: target, packagePath: packagePath)
        return [
            try renderBundleImportsIfNeeded(target, packagePath: packagePath),
            """
        apple_resource_bundle(
            name = "\(target.name)",
            bundle_id = "\(target.bundleId ?? defaultBundleId(for: target))",
        \(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    resources = \(Starlark.exprList(resources.resources, indent: 4)),
            structured_resources = \(Starlark.exprList(resources.structuredResources, indent: 4)),
        )
        """,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private mutating func renderSwiftLibrary(
        _ target: TuistTarget,
        packagePath: String,
        name: String,
        testonly: Bool,
        manual: Bool = false,
        extraDeps: [BazelLabel] = []
    ) throws -> String {
        let srcs = try sourceLabels(for: target, packagePath: packagePath)
        let deps = extraDeps
        let data = resourceGroupLabelIfNeeded(target, packagePath: packagePath)
        let testableCopts = targetsWithTestConsumers.contains(target.name) || testonly ? ["-enable-testing"] : []
        let developerSearchPath = testonly ? "    always_include_developer_search_paths = True,\n" : ""
        let testonlyAttribute = testonly ? "    testonly = True,\n" : ""
        let tagsAttribute = manual ? "    tags = [\"manual\"],\n" : ""
        let coptsAttribute = testableCopts.isEmpty ? "" : "    copts = \(Starlark.list(testableCopts, indent: 4)),\n"
        let dataAttribute = data.isEmpty ? "" : "    data = \(Starlark.list(data.map { $0.localDescription(in: packagePath) }, indent: 4)),\n"

        return """
        swift_library(
            name = "\(name)",
            srcs = \(Starlark.list(srcs, indent: 4)),
        \(developerSearchPath)\(coptsAttribute)\(dataAttribute)    module_name = "\(sanitizedModuleName(target.productName))",
        \(tagsAttribute)\(testonlyAttribute)    deps = \(Starlark.list(deps.map { $0.localDescription(in: packagePath) }, indent: 4)),
        )
        """
    }

    private mutating func renderResourceGroupIfNeeded(_ target: TuistTarget, packagePath: String) throws -> String? {
        guard !target.resources.isEmpty, target.product != .bundle else { return nil }
        let resources = try resourceExpressions(for: target, packagePath: packagePath)
        return [
            try renderBundleImportsIfNeeded(target, packagePath: packagePath),
            """
        apple_resource_group(
            name = "_\(target.name)Resources",
            resources = \(Starlark.exprList(resources.resources, indent: 4)),
            structured_resources = \(Starlark.exprList(resources.structuredResources, indent: 4)),
        )
        """,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    private mutating func sourceLabels(for target: TuistTarget, packagePath: String) throws -> [String] {
        var sources = try target.sources.filter { $0.hasSuffix(".swift") }.map {
            try paths.pathRelativeToPackage($0, packagePath: packagePath)
        }
        if let generatedAccessor = try generatedResourceAccessorSource(for: target, packagePath: packagePath) {
            sources.append(generatedAccessor)
        }
        return sources
    }

    private mutating func resourceExpressions(for target: TuistTarget, packagePath: String) throws -> (resources: [String], structuredResources: [String]) {
        var resources: Set<String> = []
        var structured: Set<String> = []

        for resource in target.resources {
            let relative = try paths.pathRelativeToPackage(resource.path, packagePath: packagePath)
            if !resource.tags.isEmpty {
                let tags = resource.tags.joined(separator: ", ")
                warnings.append("target \(target.name) has ODR tags \(tags) on \(relative); tags are not represented in generated Bazel files")
            }

            switch resource.kind {
            case .folderReference:
                structured.insert(globExpression(relative))
            case .file:
                if isDirectory(resource.path), URL(fileURLWithPath: resource.path).pathExtension == "bundle" {
                    resources.insert(Starlark.quote(":\(bundleImportName(target: target, relativePath: relative))"))
                    continue
                }
                if isDirectory(resource.path) {
                    resources.insert(globExpression(relative))
                } else {
                    resources.insert(Starlark.quote(relative))
                }
            }
        }

        return (Array(resources), Array(structured))
    }

    private func globExpression(_ relativePath: String) -> String {
        "glob([\(Starlark.quote(relativePath + "/**"))])"
    }

    private func renderBundleImportsIfNeeded(_ target: TuistTarget, packagePath: String) throws -> String? {
        let imports = try target.resources.compactMap { resource -> String? in
            guard resource.kind == .file,
                  isDirectory(resource.path),
                  URL(fileURLWithPath: resource.path).pathExtension == "bundle" else {
                return nil
            }
            let relative = try paths.pathRelativeToPackage(resource.path, packagePath: packagePath)
            return """
            apple_bundle_import(
                name = "\(bundleImportName(target: target, relativePath: relative))",
                bundle_imports = glob([\(Starlark.quote(relative + "/**"))]),
            )
            """
        }

        guard !imports.isEmpty else { return nil }
        return imports.joined(separator: "\n\n")
    }

    private func bundleImportName(target: TuistTarget, relativePath: String) -> String {
        "_\(target.name)_\(sanitizedModuleName(relativePath))"
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func resourceGroupLabelIfNeeded(_ target: TuistTarget, packagePath: String) -> [BazelLabel] {
        target.resources.isEmpty || target.product == .bundle ? [] : [BazelLabel(package: packagePath, name: "_\(target.name)Resources")]
    }

    private func libraryName(for target: TuistTarget) -> String {
        switch target.product {
        case .app, .appExtension, .framework, .staticFramework, .unitTests, .uiTests:
            "\(target.name)Lib"
        case .staticLibrary, .dynamicLibrary, .bundle, .unsupported:
            target.name
        }
    }

    private func productLabel(for target: TuistTarget) throws -> BazelLabel {
        BazelLabel(package: try paths.packagePath(for: target.projectPath), name: target.name)
    }

    private func hasSwiftLibrary(for target: TuistTarget) -> Bool {
        target.product.isSwiftBacked && (
            target.sources.contains { $0.hasSuffix(".swift") } ||
            resourceAccessors.shouldGenerate(for: target)
        )
    }

    private func libraryLabel(for target: TuistTarget) throws -> BazelLabel? {
        guard hasSwiftLibrary(for: target) else { return nil }
        return BazelLabel(package: try paths.packagePath(for: target.projectPath), name: libraryName(for: target))
    }

    private func resourceLabel(for target: TuistTarget) throws -> BazelLabel? {
        if target.product == .bundle {
            return try productLabel(for: target)
        }
        guard !target.resources.isEmpty else { return nil }
        return BazelLabel(package: try paths.packagePath(for: target.projectPath), name: "_\(target.name)Resources")
    }

    private mutating func infoplistsAttribute(_ target: TuistTarget, packagePath: String, indent: Int) -> String {
        guard let relative = infoPlistRelativePath(target, packagePath: packagePath) else {
            return ""
        }
        return "\(String(repeating: " ", count: indent))infoplists = [\(Starlark.quote(relative))],\n"
    }

    private mutating func infoPlistRelativePath(_ target: TuistTarget, packagePath: String) -> String? {
        guard let infoPlistPath = target.infoPlistPath,
              let originalRelative = try? paths.pathRelativeToPackage(infoPlistPath, packagePath: packagePath) else {
            return nil
        }

        guard let original = try? String(contentsOfFile: infoPlistPath, encoding: .utf8) else {
            return originalRelative
        }

        let replacements = [
            "$(CURRENT_PROJECT_VERSION)": "1",
            "$(MARKETING_VERSION)": "1.0",
            "$(DEVELOPMENT_LANGUAGE)": "en",
            "$(EXECUTABLE_NAME)": target.productName,
            "$(PRODUCT_BUNDLE_IDENTIFIER)": target.bundleId ?? defaultBundleId(for: target),
            "$(PRODUCT_NAME)": target.productName,
            "$(TARGET_NAME)": target.name,
        ]

        let sanitized = replacements.reduce(original) { content, replacement in
            content.replacingOccurrences(of: replacement.key, with: replacement.value)
        }
        guard sanitized != original else {
            return originalRelative
        }

        let generatedRelative = ".bazel/InfoPlists/\(target.name)-Info.plist"
        let generatedOutputPath = packagePath.isEmpty ? generatedRelative : "\(packagePath)/\(generatedRelative)"
        generatedFiles[generatedOutputPath] = sanitized
        warnings.append("generated sanitized Info.plist for \(target.name) at \(generatedOutputPath)")
        return generatedRelative
    }

    private mutating func generatedResourceAccessorSource(for target: TuistTarget, packagePath: String) throws -> String? {
        guard resourceAccessors.shouldGenerate(for: target) else {
            return nil
        }

        let relative = resourceAccessors.relativePath(for: target)
        let generatedOutputPath = packagePath.isEmpty ? relative : "\(packagePath)/\(relative)"
        if generatedFiles[generatedOutputPath] == nil {
            generatedFiles[generatedOutputPath] = resourceAccessors.render(for: target)
            warnings.append("generated synthesized resource accessors for \(target.name) at \(generatedOutputPath)")
        }
        return relative
    }

    private func optionalLabelListAttribute(_ name: String, _ labels: [BazelLabel], packagePath: String, indent: Int) -> String {
        guard !labels.isEmpty else { return "" }
        let values = labels.sorted().map { $0.localDescription(in: packagePath) }
        return "\(String(repeating: " ", count: indent))\(name) = \(Starlark.list(values, indent: indent)),\n"
    }

    private func defaultBundleId(for target: TuistTarget) -> String {
        "dev.tuist.\(sanitizedModuleName(target.name))"
    }

    private struct ResolvedDependencies {
        var codeDeps: [BazelLabel] = []
        var frameworkDeps: [BazelLabel] = []
        var extensionDeps: [BazelLabel] = []
        var resourceDeps: [BazelLabel] = []
        var testHost: BazelLabel?
    }

    private mutating func resolvedDependencies(for target: TuistTarget, packagePath: String) throws -> ResolvedDependencies {
        var result = ResolvedDependencies()

        for dependency in target.dependencies {
            if let dependencyTarget = resolveTargetDependency(dependency) {
                switch dependencyTarget.product {
                case .framework where target.product == .app || target.product == .appExtension:
                    if let library = try libraryLabel(for: dependencyTarget) {
                        result.codeDeps.append(library)
                    }
                    result.frameworkDeps.append(try productLabel(for: dependencyTarget))
                case .appExtension where target.product == .app:
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
                    if let resource = try resourceLabel(for: dependencyTarget), dependencyTarget.sources.isEmpty {
                        result.resourceDeps.append(resource)
                    }
                }
                continue
            }

            switch dependency {
            case let .package(product):
                warnings.append("package dependency \(product) on target \(target.name) is not generated yet")
            case let .sdk(name):
                warnings.append("SDK dependency \(name) on target \(target.name) is not generated yet")
            case let .framework(path), let .xcframework(path), let .library(path):
                warnings.append("binary dependency \(path) on target \(target.name) is not generated yet")
            case .xctest:
                break
            case .target, .project:
                warnings.append("unresolved target dependency on \(target.name)")
            }
        }

        result.codeDeps = Array(Set(result.codeDeps)).sorted()
        result.frameworkDeps = Array(Set(result.frameworkDeps)).sorted()
        result.extensionDeps = Array(Set(result.extensionDeps)).sorted()
        result.resourceDeps = Array(Set(result.resourceDeps)).sorted()
        return result
    }

    private func resolveTargetDependency(_ dependency: TuistDependency) -> TuistTarget? {
        switch dependency {
        case let .target(name):
            targetsByName[name]
        case let .project(target, path):
            targetsByPathAndName[indexKey(path: path, name: target)] ?? targetsByName[target]
        case .framework, .xcframework, .library, .package, .sdk, .xctest:
            nil
        }
    }
}
