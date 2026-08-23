import Foundation

extension BazelGenerator {
    mutating func renderResourceBundle(_ target: TuistTarget, packagePath: String) throws -> String {
        let resources = try resourceExpressions(for: target, packagePath: packagePath)
        return [
            try renderBundleImportsIfNeeded(target, packagePath: packagePath),
            """
        apple_resource_bundle(
            name = "\(target.name)",
            bundle_id = "\(resolvedBundleId(for: target))",
        \(infoplistsAttribute(target, packagePath: packagePath, indent: 4))    resources = \(Starlark.exprList(resources.resources, indent: 4)),
            structured_resources = \(Starlark.exprList(resources.structuredResources, indent: 4)),
        )
        """,
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }

    mutating func renderSwiftLibrary(
        _ target: TuistTarget,
        packagePath: String,
        name: String,
        testonly: Bool,
        manual: Bool = false,
        resolved deps: ResolvedDependencies
    ) throws -> String {
        try renderSwiftLibrary(
            target,
            packagePath: packagePath,
            name: name,
            testonly: testonly,
            manual: manual,
            extraDeps: deps.codeDeps,
            pluginDeps: deps.pluginDeps,
            linkopts: deps.linkopts,
            includeDeveloperSearchPaths: deps.includeDeveloperSearchPaths
        )
    }

    mutating func renderSwiftLibrary(
        _ target: TuistTarget,
        packagePath: String,
        name: String,
        testonly: Bool,
        manual: Bool = false,
        extraDeps: [BazelLabel] = [],
        pluginDeps: [BazelLabel] = [],
        linkopts: [String] = [],
        includeDeveloperSearchPaths: Bool = false
    ) throws -> String {
        let srcs = try sourceLabels(for: target, packagePath: packagePath)
        let deps = extraDeps
        // Dynamic framework resources belong to the framework bundle itself. Attaching
        // them to its backing library makes rules_apple flatten every transitive
        // framework resource into a consuming framework, where common localized file
        // names such as Localizable.strings collide.
        let data = target.product == .framework
            ? []
            : resourceGroupLabelIfNeeded(target, packagePath: packagePath)
        var compilerOptions = targetsWithTestConsumers.contains(target.name) || testonly ? ["-enable-testing"] : []
        if let swiftLanguageMode = target.swiftLanguageMode {
            compilerOptions.append(contentsOf: ["-swift-version", swiftLanguageMode])
        }
        let developerSearchPath = testonly || includeDeveloperSearchPaths ? "    always_include_developer_search_paths = True,\n" : ""
        let testonlyAttribute = testonly ? "    testonly = True,\n" : ""
        let tagsAttribute = manual ? "    tags = [\"manual\"],\n" : ""
        let coptsAttribute = compilerOptions.isEmpty
            ? ""
            : "    copts = \(Starlark.orderedList(compilerOptions, indent: 4)),\n"
        let dataAttribute = data.isEmpty ? "" : "    data = \(Starlark.list(data.map { $0.localDescription(in: packagePath) }, indent: 4)),\n"
        let linkoptsAttribute = linkopts.isEmpty ? "" : "    linkopts = \(Starlark.orderedList(linkopts, indent: 4)),\n"
        let plugins = pluginDeps.map { $0.localDescription(in: packagePath) }
        let pluginsAttribute = plugins.isEmpty ? "" : "    plugins = \(Starlark.list(plugins, indent: 4)),\n"

        return """
        swift_library(
            name = "\(name)",
            srcs = \(Starlark.list(srcs, indent: 4)),
        \(developerSearchPath)\(coptsAttribute)\(dataAttribute)\(linkoptsAttribute)    module_name = "\(sanitizedModuleName(target.productName))",
        \(pluginsAttribute)\(tagsAttribute)\(testonlyAttribute)    deps = \(Starlark.list(deps.map { $0.localDescription(in: packagePath) }, indent: 4)),
        )
        """
    }

    mutating func renderResourceGroupIfNeeded(_ target: TuistTarget, packagePath: String) throws -> String? {
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

    mutating func sourceLabels(for target: TuistTarget, packagePath: String) throws -> [String] {
        var sources = try target.sources.filter { $0.hasSuffix(".swift") }.map {
            try paths.pathRelativeToPackage($0, packagePath: packagePath)
        }
        if let generatedAccessor = try generatedResourceAccessorSource(for: target, packagePath: packagePath) {
            sources.append(generatedAccessor)
        }
        return sources
    }

    mutating func resourceExpressions(for target: TuistTarget, packagePath: String) throws -> (resources: [String], structuredResources: [String]) {
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

    func globExpression(_ relativePath: String) -> String {
        "glob([\(Starlark.quote(relativePath + "/**"))])"
    }

    func renderBundleImportsIfNeeded(_ target: TuistTarget, packagePath: String) throws -> String? {
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

    func bundleImportName(target: TuistTarget, relativePath: String) -> String {
        "_\(target.name)_\(sanitizedModuleName(relativePath))"
    }

    func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func resourceGroupLabelIfNeeded(_ target: TuistTarget, packagePath: String) -> [BazelLabel] {
        target.resources.isEmpty || target.product == .bundle ? [] : [BazelLabel(package: packagePath, name: "_\(target.name)Resources")]
    }

    func libraryName(for target: TuistTarget) -> String {
        BazelDependencyResolver.libraryName(for: target)
    }

    func productLabel(for target: TuistTarget) throws -> BazelLabel {
        try makeDependencyResolver().productLabel(for: target)
    }

    func hasSwiftLibrary(for target: TuistTarget) -> Bool {
        makeDependencyResolver().hasSwiftLibrary(for: target)
    }

    func libraryLabel(for target: TuistTarget) throws -> BazelLabel? {
        try makeDependencyResolver().libraryLabel(for: target)
    }

    func resourceLabel(for target: TuistTarget) throws -> BazelLabel? {
        try makeDependencyResolver().resourceLabel(for: target)
    }

    mutating func generatedResourceAccessorSource(for target: TuistTarget, packagePath: String) throws -> String? {
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

    func optionalLabelListAttribute(_ name: String, _ labels: [BazelLabel], packagePath: String, indent: Int) -> String {
        guard !labels.isEmpty else { return "" }
        let values = labels.sorted().map { $0.localDescription(in: packagePath) }
        return "\(String(repeating: " ", count: indent))\(name) = \(Starlark.list(values, indent: indent)),\n"
    }

    func optionalLabelAttribute(_ name: String, _ label: BazelLabel?, packagePath: String, indent: Int) -> String {
        guard let label else { return "" }
        return "\(String(repeating: " ", count: indent))\(name) = \"\(label.localDescription(in: packagePath))\",\n"
    }

}
