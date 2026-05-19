import Foundation

struct TuistGraphParser {
    func parse(data: Data) throws -> TuistGraph {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let rootObject = root.objectValue else {
            throw ConversionError.invalidGraph("expected top-level JSON object")
        }

        let name = rootObject["name"]?.stringValue ?? "App"
        guard let projectsValue = rootObject["projects"] else {
            throw ConversionError.invalidGraph("missing projects")
        }

        return TuistGraph(
            name: name,
            projects: try parseProjects(projectsValue),
            localSwiftPackages: parseLocalSwiftPackages(rootObject["packages"]).map(TuistLocalSwiftPackage.init(path:)),
            remoteSwiftPackages: parseRemoteSwiftPackages(rootObject["packages"])
        )
    }

    private func parseProjects(_ value: JSONValue) throws -> [TuistProject] {
        if let object = value.objectValue {
            return try object.map { path, project in
                try parseProject(path: path, value: project)
            }.sorted { $0.path < $1.path }
        }

        guard let array = value.arrayValue else {
            throw ConversionError.invalidGraph("projects must be an object or alternating array")
        }
        guard array.count.isMultiple(of: 2) else {
            throw ConversionError.invalidGraph("projects alternating array has an odd number of entries")
        }

        var projects: [TuistProject] = []
        var index = 0
        while index < array.count {
            guard let path = array[index].stringValue else {
                throw ConversionError.invalidGraph("project key at index \(index) is not a string path")
            }
            projects.append(try parseProject(path: path, value: array[index + 1]))
            index += 2
        }
        return projects
    }

    private func parseProject(path: String, value: JSONValue) throws -> TuistProject {
        guard let object = value.objectValue else {
            throw ConversionError.invalidGraph("project at \(path) is not an object")
        }
        guard let targetsObject = object["targets"]?.objectValue else {
            throw ConversionError.invalidGraph("project at \(path) has no targets object")
        }

        let targets = try targetsObject.map { targetName, targetValue in
            try parseTarget(name: targetName, projectPath: path, value: targetValue)
        }.sorted { $0.name < $1.name }

        return TuistProject(
            name: object["name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent,
            path: path,
            targets: targets
        )
    }

    private func parseTarget(name: String, projectPath: String, value: JSONValue) throws -> TuistTarget {
        guard let object = value.objectValue else {
            throw ConversionError.invalidGraph("target \(name) is not an object")
        }

        let product = ProductType(rawGraphValue: object["product"]?.stringValue ?? "unsupported")
        let buildableFolderFiles = parseBuildableFolderFiles(object["buildableFolders"])
        let settingsInfoPlistEntries = parseSettingsInfoPlistEntries(object["settings"])
        let explicitInfoPlistEntries = parseInfoPlistEntries(object["infoPlist"])
        return TuistTarget(
            name: name,
            product: product,
            destinations: parseStringArray(object["destinations"]),
            bundleId: object["bundleId"]?.stringValue,
            productName: object["productName"]?.stringValue ?? sanitizedModuleName(name),
            projectPath: projectPath,
            infoPlistPath: parseInfoPlist(object["infoPlist"]),
            infoPlistEntries: settingsInfoPlistEntries.merging(explicitInfoPlistEntries) { _, explicit in explicit },
            sources: orderedUnique(parsePathArray(object["sources"]) + buildableFolderFiles.filter(isBuildableSource)),
            headers: parseHeaders(object["headers"]),
            coreDataModels: parseCoreDataModels(object["coreDataModels"]),
            resources: parseResources(object["resources"]) + buildableFolderFiles.filter(isBuildableResource).map {
                TuistResource(path: $0, kind: .file, tags: [])
            },
            dependencies: parseDependencies(object["dependencies"])
        )
    }

    private func parseInfoPlist(_ value: JSONValue?) -> String? {
        guard let object = value?.objectValue else { return nil }
        if let path = object["file"]?["path"]?.stringValue {
            return path
        }
        if let path = object["generatedFile"]?["path"]?.stringValue {
            return path
        }
        return nil
    }

    private func parseInfoPlistEntries(_ value: JSONValue?) -> [String: PlistValue] {
        guard let entries = value?["extendingDefault"]?["with"]?.objectValue else {
            return [:]
        }
        return entries.reduce(into: [:]) { result, element in
            if let parsed = parsePlistValue(element.value) {
                result[element.key] = parsed
            }
        }
    }

    private func parsePlistValue(_ value: JSONValue?) -> PlistValue? {
        guard let object = value?.objectValue else {
            switch value {
            case let .string(string):
                return .string(string)
            case let .bool(bool):
                return .bool(bool)
            case let .number(number):
                return .number(number)
            case let .array(values):
                return .array(values.compactMap(parsePlistValue))
            default:
                return nil
            }
        }

        if let string = object["string"]?["_0"]?.stringValue {
            return .string(string)
        }
        if let bool = object["boolean"]?["_0"], case let .bool(value) = bool {
            return .bool(value)
        }
        if let number = object["integer"]?["_0"], case let .number(value) = number {
            return .number(value)
        }
        if let number = object["real"]?["_0"], case let .number(value) = number {
            return .number(value)
        }
        if let values = object["array"]?["_0"]?.arrayValue {
            return .array(values.compactMap(parsePlistValue))
        }
        if let values = object["dictionary"]?["_0"]?.objectValue {
            return .dictionary(values.reduce(into: [:]) { result, element in
                if let parsed = parsePlistValue(element.value) {
                    result[element.key] = parsed
                }
            })
        }
        return nil
    }

    private func parseSettingsInfoPlistEntries(_ value: JSONValue?) -> [String: PlistValue] {
        guard let baseSettings = value?["base"]?.objectValue else {
            return [:]
        }
        var entries: [String: PlistValue] = [:]
        for (key, value) in baseSettings {
            if key.hasPrefix("INFOPLIST_KEY_"),
               let parsed = parseBuildSettingPlistValue(value) {
                entries[String(key.dropFirst("INFOPLIST_KEY_".count))] = parsed
            }
        }
        if let version = parseBuildSettingPlistValue(baseSettings["CURRENT_PROJECT_VERSION"]) {
            entries["CFBundleVersion"] = version
        }
        if let version = parseBuildSettingPlistValue(baseSettings["MARKETING_VERSION"]) {
            entries["CFBundleShortVersionString"] = version
        }
        return entries
    }

    private func parseBuildSettingPlistValue(_ value: JSONValue?) -> PlistValue? {
        if let string = value?["string"]?["_0"]?.stringValue {
            switch string {
            case "YES":
                return .bool(true)
            case "NO":
                return .bool(false)
            default:
                return .string(string)
            }
        }
        if let values = value?["array"]?["_0"]?.arrayValue {
            return .array(values.compactMap(parsePlistValue))
        }
        return parsePlistValue(value)
    }

    private func parsePathArray(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap { element in
            element["path"]?.stringValue
        } ?? []
    }

    private func parseBuildableFolderFiles(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.flatMap { folder in
            folder["resolvedFiles"]?.arrayValue?.compactMap { element in
                element["path"]?.stringValue
            } ?? []
        } ?? []
    }

    private func isBuildableSource(_ path: String) -> Bool {
        ["swift", "c", "cc", "cpp", "cxx", "m", "mm"].contains(URL(fileURLWithPath: path).pathExtension)
    }

    private func isBuildableResource(_ path: String) -> Bool {
        let ignoredExtensions = ["h", "hh", "hpp", "hxx"]
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        return !isBuildableSource(path) && !ignoredExtensions.contains(URL(fileURLWithPath: path).pathExtension) && fileName != ".DS_Store"
    }

    private func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var genericSeen: Set<T> = []
        return values.filter { genericSeen.insert($0).inserted }
    }

    private func parseResources(_ value: JSONValue?) -> [TuistResource] {
        guard let rawResources = value?["resources"]?.arrayValue else { return [] }
        return rawResources.compactMap { element in
            if let file = element["file"]?.objectValue, let path = file["path"]?.stringValue {
                return TuistResource(path: path, kind: .file, tags: parseTags(file["tags"]))
            }
            if let folder = element["folderReference"]?.objectValue, let path = folder["path"]?.stringValue {
                return TuistResource(path: path, kind: .folderReference, tags: parseTags(folder["tags"]))
            }
            return nil
        }
    }

    private func parseCoreDataModels(_ value: JSONValue?) -> [TuistCoreDataModel] {
        guard let models = value?.arrayValue else { return [] }
        return models.compactMap { element in
            guard let path = element["path"]?.stringValue else {
                return nil
            }
            return TuistCoreDataModel(
                path: path,
                currentVersion: element["currentVersion"]?.stringValue,
                versions: parseStringArray(element["versions"])
            )
        }
    }

    private func parseHeaders(_ value: JSONValue?) -> TuistHeaders {
        TuistHeaders(
            publicHeaders: parseHeaderGroup(value?["public"]),
            privateHeaders: parseHeaderGroup(value?["private"]),
            projectHeaders: parseHeaderGroup(value?["project"])
        )
    }

    private func parseHeaderGroup(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func parseStringArray(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func parseLocalSwiftPackages(_ value: JSONValue?) -> [String] {
        var paths: [String] = []
        collectLocalSwiftPackages(value, into: &paths)
        return orderedUnique(paths)
    }

    private func collectLocalSwiftPackages(_ value: JSONValue?, into paths: inout [String]) {
        guard let value else { return }
        if let path = value["local"]?["path"]?.stringValue {
            paths.append(path)
        }
        if let object = value.objectValue {
            for child in object.values {
                collectLocalSwiftPackages(child, into: &paths)
            }
        }
        if let array = value.arrayValue {
            for child in array {
                collectLocalSwiftPackages(child, into: &paths)
            }
        }
    }

    private func parseRemoteSwiftPackages(_ value: JSONValue?) -> [TuistRemoteSwiftPackage] {
        var packages: [TuistRemoteSwiftPackage] = []
        collectRemoteSwiftPackages(value, into: &packages)
        return orderedUnique(packages)
    }

    private func collectRemoteSwiftPackages(_ value: JSONValue?, into packages: inout [TuistRemoteSwiftPackage]) {
        guard let value else { return }
        if let remote = value["remote"]?.objectValue,
           let url = remote["url"]?.stringValue,
           let requirement = parseSwiftPackageRequirement(remote["requirement"]) {
            packages.append(TuistRemoteSwiftPackage(url: url, requirement: requirement))
        }
        if let object = value.objectValue {
            for child in object.values {
                collectRemoteSwiftPackages(child, into: &packages)
            }
        }
        if let array = value.arrayValue {
            for child in array {
                collectRemoteSwiftPackages(child, into: &packages)
            }
        }
    }

    private func parseSwiftPackageRequirement(_ value: JSONValue?) -> SwiftPackageRequirement? {
        guard let object = value?.objectValue else {
            return nil
        }
        if let version = object["upToNextMajor"]?["_0"]?.stringValue {
            return .upToNextMajor(version)
        }
        if let version = object["upToNextMinor"]?["_0"]?.stringValue {
            return .upToNextMinor(version)
        }
        if let version = object["exact"]?["_0"]?.stringValue {
            return .exact(version)
        }
        if let branch = object["branch"]?["_0"]?.stringValue {
            return .branch(branch)
        }
        if let revision = object["revision"]?["_0"]?.stringValue {
            return .revision(revision)
        }
        return nil
    }

    private func parseTags(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func parseDependencies(_ value: JSONValue?) -> [TuistDependency] {
        value?.arrayValue?.compactMap { element in
            if let target = element["target"]?.objectValue, let name = target["name"]?.stringValue {
                return .target(name: name, condition: parseDependencyCondition(target["condition"]))
            }
            if let project = element["project"]?.objectValue,
               let target = project["target"]?.stringValue,
               let path = project["path"]?.stringValue {
                return .project(target: target, path: path, condition: parseDependencyCondition(project["condition"]))
            }
            if let framework = element["framework"]?.objectValue, let path = framework["path"]?.stringValue {
                return .framework(path: path)
            }
            if let xcframework = element["xcframework"]?.objectValue, let path = xcframework["path"]?.stringValue {
                return .xcframework(path: path)
            }
            if let library = element["library"]?.objectValue, let path = library["path"]?.stringValue {
                return .library(
                    path: path,
                    publicHeaders: library["publicHeaders"]?.stringValue,
                    swiftModuleMap: library["swiftModuleMap"]?.stringValue
                )
            }
            if let package = element["package"]?.objectValue, let product = package["product"]?.stringValue {
                let rawType = package["type"]?.stringValue ?? ""
                let kind: PackageDependencyKind = rawType.contains("plugin") ? .plugin : .runtime
                return .package(product: product, kind: kind)
            }
            if let sdk = element["sdk"]?.objectValue, let name = sdk["name"]?.stringValue {
                return .sdk(name: name, status: sdk["status"]?.stringValue)
            }
            if element["xctest"] != nil {
                return .xctest
            }
            return nil
        } ?? []
    }

    private func parseDependencyCondition(_ value: JSONValue?) -> TuistDependencyCondition? {
        let platformFilters: [String] = value?["platformFilters"]?.arrayValue?.flatMap { filter -> [String] in
            guard let object = filter.objectValue else {
                return []
            }
            return Array(object.keys)
        } ?? []
        guard !platformFilters.isEmpty else {
            return nil
        }
        return TuistDependencyCondition(platformFilters: orderedUnique(platformFilters))
    }
}
