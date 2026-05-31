import Foundation

extension BazelGenerator {
    mutating func renderResourceBundle(_ target: TuistTarget, packagePath: String) throws -> String {
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

    func renderCoreDataModelIfNeeded(_ target: TuistTarget, packagePath: String) throws -> String? {
        guard !target.coreDataModels.isEmpty else {
            return nil
        }
        let srcExpressions = try target.coreDataModels.flatMap { model in
            try currentModelContentsPaths(for: model).map { contentsPath in
                Starlark.quote(try paths.pathRelativeToPackage(contentsPath, packagePath: packagePath))
            }
        }
        return """
        apple_core_data_model(
            name = "\(coreDataModelSourceName(for: target))",
            srcs = \(Starlark.exprList(srcExpressions, indent: 4)),
            outs = \(try renderCoreDataModelOuts(for: target, packagePath: packagePath)),
            swift_version = "5",
        )
        """
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
            sdkFrameworks: deps.sdkFrameworks,
            weakSdkFrameworks: deps.weakSdkFrameworks,
            sdkDylibs: deps.sdkDylibs,
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
        sdkFrameworks: [String] = [],
        weakSdkFrameworks: [String] = [],
        sdkDylibs: [String] = [],
        linkopts: [String] = [],
        includeDeveloperSearchPaths: Bool = false
    ) throws -> String {
        let srcs = try sourceLabels(for: target, packagePath: packagePath)
        var clangSrcs = try clangSourceLabels(for: target, packagePath: packagePath)
        let headers = try headerLabels(for: target, packagePath: packagePath)
        let deps = extraDeps
        let data = resourceGroupLabelIfNeeded(target, packagePath: packagePath)
        let testableCopts = targetsWithTestConsumers.contains(target.name) || testonly ? ["-enable-testing"] : []
        let developerSearchPath = testonly || includeDeveloperSearchPaths ? "    always_include_developer_search_paths = True,\n" : ""
        let testonlyAttribute = testonly ? "    testonly = True,\n" : ""
        let tagsAttribute = manual ? "    tags = [\"manual\"],\n" : ""
        let coptsAttribute = testableCopts.isEmpty ? "" : "    copts = \(Starlark.list(testableCopts, indent: 4)),\n"
        let dataAttribute = data.isEmpty ? "" : "    data = \(Starlark.list(data.map { $0.localDescription(in: packagePath) }, indent: 4)),\n"
        let linkoptsAttribute = linkopts.isEmpty ? "" : "    linkopts = \(Starlark.orderedList(linkopts, indent: 4)),\n"
        let plugins = pluginDeps.map { $0.localDescription(in: packagePath) }
        let pluginsAttribute = plugins.isEmpty ? "" : "    plugins = \(Starlark.list(plugins, indent: 4)),\n"
        let swiftPluginsAttribute = plugins.isEmpty ? "" : "    swift_plugins = \(Starlark.list(plugins, indent: 4)),\n"

        if clangSrcs.isEmpty, requiresObjCLibrary(target), target.sources.contains(where: isClangSource) {
            clangSrcs.append(generatedObjCStubSource(for: target, packagePath: packagePath))
        }

        if !clangSrcs.isEmpty || !headers.isEmpty {
            let umbrella = umbrellaHeader(for: target, headers: headers)
            let hdrs = umbrella.map { umbrella in headers.filter { $0 != umbrella } } ?? headers
            let includes = includeDirectories(for: headers)
            let includesAttribute = includes.isEmpty ? "" : "    includes = \(Starlark.list(includes, indent: 4)),\n"
            let sdkFrameworksAttribute = sdkFrameworks.isEmpty ? "" : "    sdk_frameworks = \(Starlark.list(sdkFrameworks, indent: 4)),\n"
            let weakSdkFrameworksAttribute = weakSdkFrameworks.isEmpty ? "" : "    weak_sdk_frameworks = \(Starlark.list(weakSdkFrameworks, indent: 4)),\n"
            let sdkDylibsAttribute = sdkDylibs.isEmpty ? "" : "    sdk_dylibs = \(Starlark.list(sdkDylibs, indent: 4)),\n"
            let swiftCoptsAttribute = testableCopts.isEmpty ? "" : "    swift_copts = \(Starlark.list(testableCopts, indent: 4)),\n"

            if srcs.isEmpty {
                return """
                objc_library(
                    name = "\(name)",
                    srcs = \(Starlark.list(clangSrcs, indent: 4)),
                    hdrs = \(Starlark.list(hdrs, indent: 4)),
                \(dataAttribute)    enable_modules = True,
                \(includesAttribute)\(linkoptsAttribute)    module_name = "\(sanitizedModuleName(target.productName))",
                \(sdkDylibsAttribute)\(sdkFrameworksAttribute)\(tagsAttribute)\(testonlyAttribute)\(weakSdkFrameworksAttribute)    deps = \(Starlark.list(deps.map { $0.localDescription(in: packagePath) }, indent: 4)),
                )
                """
            }

            return """
            mixed_language_library(
                name = "\(name)",
                clang_srcs = \(Starlark.list(clangSrcs, indent: 4)),
                hdrs = \(Starlark.list(hdrs, indent: 4)),
            \(developerSearchPath)\(dataAttribute)    enable_modules = True,
            \(includesAttribute)\(linkoptsAttribute)    module_name = "\(sanitizedModuleName(target.productName))",
            \(sdkDylibsAttribute)\(sdkFrameworksAttribute)\(swiftCoptsAttribute)\(swiftPluginsAttribute)    swift_srcs = \(Starlark.list(srcs, indent: 4)),
            \(tagsAttribute)\(testonlyAttribute)\(weakSdkFrameworksAttribute)    deps = \(Starlark.list(deps.map { $0.localDescription(in: packagePath) }, indent: 4)),
            )
            """
        }

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
        guard (!target.resources.isEmpty || !target.coreDataModels.isEmpty), target.product != .bundle else { return nil }
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
        if !target.coreDataModels.isEmpty {
            sources.append(":\(coreDataModelSourceName(for: target))")
        }
        if let generatedAccessor = try generatedResourceAccessorSource(for: target, packagePath: packagePath) {
            sources.append(generatedAccessor)
        }
        return sources
    }

    mutating func generatedObjCStubSource(for target: TuistTarget, packagePath: String) -> String {
        let relative = ".bazel/Generated/\(sanitizedModuleName(target.name))ObjCStub.m"
        let generatedOutputPath = packagePath.isEmpty ? relative : "\(packagePath)/\(relative)"
        if generatedFiles[generatedOutputPath] == nil {
            generatedFiles[generatedOutputPath] = "void _\(sanitizedModuleName(target.name))BazelObjCStub(void) {}\n"
            warnings.append("generated Objective-C stub for \(target.name) at \(generatedOutputPath)")
        }
        return relative
    }

    func requiresMixedLanguage(_ target: TuistTarget) -> Bool {
        hasRenderableObjCInputs(target) && hasSwiftInputs(target)
    }

    func requiresObjCLibrary(_ target: TuistTarget) -> Bool {
        requiresObjCInterop(target) && !hasSwiftInputs(target)
    }

    func requiresObjCInterop(_ target: TuistTarget) -> Bool {
        target.sources.contains(where: isClangSource) || !target.headers.all.isEmpty
    }

    func hasRenderableObjCInputs(_ target: TuistTarget) -> Bool {
        target.sources.contains { isClangSource($0) && !isAutoLinkingStubFile($0) }
            || target.headers.all.contains { !isAutoLinkingStubFile($0) }
    }

    func hasSwiftInputs(_ target: TuistTarget) -> Bool {
        target.sources.contains { $0.hasSuffix(".swift") }
            || resourceAccessors.shouldGenerate(for: target)
    }

    func isClangSource(_ path: String) -> Bool {
        BazelDependencyResolver.isClangSource(path)
    }

    func clangSourceLabels(for target: TuistTarget, packagePath: String) throws -> [String] {
        try target.sources.filter { isClangSource($0) && !isAutoLinkingStubFile($0) }.map {
            try paths.pathRelativeToPackage($0, packagePath: packagePath)
        }
    }

    func isAutoLinkingStubFile(_ path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }

        let withoutBlockComments = replacingMatches(
            pattern: #"/\*.*?\*/"#,
            in: content,
            options: [.dotMatchesLineSeparators],
            with: ""
        )
        let code = withoutBlockComments
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return firstMatch(pattern: #"^@import\s+[A-Za-z_][A-Za-z0-9_]*\s*;$"#, in: code) != nil
    }

    func headerLabels(for target: TuistTarget, packagePath: String) throws -> [String] {
        try target.headers.all.filter { !isAutoLinkingStubFile($0) }.map {
            try paths.pathRelativeToPackage($0, packagePath: packagePath)
        }
    }

    func umbrellaHeader(for target: TuistTarget, headers: [String]) -> String? {
        let candidates = ["\(target.productName).h", "\(target.name).h"]
        return headers.first { candidates.contains(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    func includeDirectories(for headers: [String]) -> [String] {
        Array(Set(headers.map { ($0 as NSString).deletingLastPathComponent })).sorted()
    }

    mutating func resourceExpressions(for target: TuistTarget, packagePath: String) throws -> (resources: [String], structuredResources: [String]) {
        var resources: Set<String> = []
        var structured: Set<String> = []

        for resource in target.resources + target.coreDataModels.map({ TuistResource(path: $0.path, kind: .file, tags: []) }) {
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

    func coreDataModelSourceName(for target: TuistTarget) -> String {
        "_\(sanitizedModuleName(target.name))CoreDataSources"
    }

    func renderCoreDataModelOuts(for target: TuistTarget, packagePath: String) throws -> String {
        let entries = target.coreDataModels.map { model -> (name: String, files: [String]) in
            let modelName = URL(fileURLWithPath: model.path).deletingPathExtension().lastPathComponent
            let classFiles = coreDataClassNames(for: model).map { "\($0)+CoreDataProperties.swift" }
            return (modelName, ["\(modelName)+CoreDataModel.swift"] + classFiles)
        }
        guard !entries.isEmpty else {
            return "{}"
        }

        let body = entries
            .sorted { $0.name < $1.name }
            .map { entry in
                "        \(Starlark.quote(entry.name)): \(Starlark.orderedList(entry.files, indent: 8)),"
            }
            .joined(separator: "\n")
        return "{\n\(body)\n    }"
    }

    func coreDataClassNames(for model: TuistCoreDataModel) -> [String] {
        var classes: Set<String> = []
        for contentsPath in currentModelContentsPaths(for: model) {
            classes.formUnion(coreDataClassNames(inModelContents: contentsPath))
        }
        return Array(classes).sorted()
    }

    func currentModelContentsPaths(for model: TuistCoreDataModel) -> [String] {
        let versions = model.versions.isEmpty ? [model.path] : model.versions
        let selectedVersion = model.currentVersion.flatMap { currentVersion in
            versions.first { version in
                let versionName = URL(fileURLWithPath: version).deletingPathExtension().lastPathComponent
                return versionName == currentVersion || URL(fileURLWithPath: version).lastPathComponent == currentVersion
            }
        }

        let modelPaths = selectedVersion.map { [$0] } ?? versions
        return modelPaths.map { path in
            URL(fileURLWithPath: path).appendingPathComponent("contents").path
        }
    }

    func coreDataClassNames(inModelContents path: String) -> [String] {
        guard let document = try? XMLDocument(contentsOf: URL(fileURLWithPath: path), options: []),
              let entities = try? document.nodes(forXPath: "//entity") else {
            return []
        }
        return entities.compactMap { node -> String? in
            guard let element = node as? XMLElement,
                  let name = element.attribute(forName: "name")?.stringValue else {
                return nil
            }
            let className = element.attribute(forName: "representedClassName")?.stringValue ?? name
            return swiftTypeIdentifier(className, fallback: name)
        }
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
        (target.resources.isEmpty && target.coreDataModels.isEmpty) || target.product == .bundle ? [] : [BazelLabel(package: packagePath, name: "_\(target.name)Resources")]
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
