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
            projects: try parseProjects(projectsValue)
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
        return TuistTarget(
            name: name,
            product: product,
            bundleId: object["bundleId"]?.stringValue,
            productName: object["productName"]?.stringValue ?? sanitizedModuleName(name),
            projectPath: projectPath,
            infoPlistPath: parseInfoPlist(object["infoPlist"]),
            sources: parsePathArray(object["sources"]),
            headers: parseHeaders(object["headers"]),
            resources: parseResources(object["resources"]),
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

    private func parsePathArray(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap { element in
            element["path"]?.stringValue
        } ?? []
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

    private func parseTags(_ value: JSONValue?) -> [String] {
        value?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    private func parseDependencies(_ value: JSONValue?) -> [TuistDependency] {
        value?.arrayValue?.compactMap { element in
            if let target = element["target"]?.objectValue, let name = target["name"]?.stringValue {
                return .target(name: name)
            }
            if let project = element["project"]?.objectValue,
               let target = project["target"]?.stringValue,
               let path = project["path"]?.stringValue {
                return .project(target: target, path: path)
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
                return .package(product: product)
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
}
