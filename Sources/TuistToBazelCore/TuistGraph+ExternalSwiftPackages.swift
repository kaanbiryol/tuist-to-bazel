import Foundation

extension TuistGraph {
    mutating func routeExternalSwiftPackageProjects(rootPath: URL) throws {
        let checkoutsRoot = rootPath
            .appendingPathComponent("Tuist/.build/checkouts", isDirectory: true)
            .standardizedFileURL.path
        let pins = try resolvedSwiftPackagePins(rootPath: rootPath)
        guard !pins.isEmpty else {
            return
        }

        let pinsByCheckoutName = pins.reduce(into: [String: ResolvedSwiftPackagePin]()) { result, pin in
            result[comparablePackageName(pin.identity)] = pin
            result[comparablePackageName(packageName(from: pin.url))] = pin
        }
        let packageByProjectPath: [String: ResolvedSwiftPackagePin] = Dictionary(
            uniqueKeysWithValues: projects.compactMap { project -> (String, ResolvedSwiftPackagePin)? in
                guard let checkoutName = checkoutName(for: project.path, checkoutsRoot: checkoutsRoot),
                      let pin = pinsByCheckoutName[comparablePackageName(checkoutName)] else {
                    return nil
                }
                return (project.path, pin)
            }
        )
        guard !packageByProjectPath.isEmpty else {
            return
        }

        var routedPackages: [TuistRemoteSwiftPackage] = []
        var localProjects: [TuistProject] = []
        for var project in projects where packageByProjectPath[project.path] == nil {
            var projectPackages: [TuistRemoteSwiftPackage] = []
            project.targets = project.targets.map { target in
                var target = target
                target.dependencies = target.dependencies.map { dependency in
                    guard case let .project(product, path, condition) = dependency,
                          let pin = packageByProjectPath[path] else {
                        return dependency
                    }
                    let package = TuistRemoteSwiftPackage(url: pin.url, requirement: pin.requirement)
                    projectPackages.append(package)
                    routedPackages.append(package)
                    return .package(
                        product: product,
                        url: pin.url,
                        condition: condition
                    )
                }
                return target
            }
            if !projectPackages.isEmpty {
                remoteSwiftPackagesByProjectPath[project.path] = orderedUnique(
                    (remoteSwiftPackagesByProjectPath[project.path] ?? []) + projectPackages
                )
            }
            localProjects.append(project)
        }

        projects = localProjects
        remoteSwiftPackages = orderedUnique(remoteSwiftPackages + routedPackages)
    }

    private func resolvedSwiftPackagePins(rootPath: URL) throws -> [ResolvedSwiftPackagePin] {
        let fileManager = FileManager.default
        guard let resolvedURL = [
            rootPath.appendingPathComponent("Package.resolved"),
            rootPath.appendingPathComponent(".package.resolved"),
            rootPath.appendingPathComponent("Tuist/Package.resolved"),
        ].first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            return []
        }

        let data = try Data(contentsOf: resolvedURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConversionError.invalidGraph("Package.resolved is not a JSON object")
        }
        let rawPins: [[String: Any]]
        if let pins = root["pins"] as? [[String: Any]] {
            rawPins = pins
        } else if let object = root["object"] as? [String: Any],
                  let pins = object["pins"] as? [[String: Any]] {
            rawPins = pins
        } else {
            return []
        }

        return rawPins.compactMap { pin in
            guard let state = pin["state"] as? [String: Any],
                  let url = (pin["location"] as? String) ?? (pin["repositoryURL"] as? String),
                  let requirement = swiftPackageRequirement(from: state) else {
                return nil
            }
            let identity = (pin["identity"] as? String)
                ?? (pin["package"] as? String)
                ?? packageName(from: url)
            return ResolvedSwiftPackagePin(identity: identity, url: url, requirement: requirement)
        }
    }

    private func swiftPackageRequirement(from state: [String: Any]) -> SwiftPackageRequirement? {
        if let version = state["version"] as? String {
            return .exact(version)
        }
        if let branch = state["branch"] as? String {
            return .branch(branch)
        }
        if let revision = state["revision"] as? String {
            return .revision(revision)
        }
        return nil
    }

    private func checkoutName(for path: String, checkoutsRoot: String) -> String? {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = checkoutsRoot.hasSuffix("/") ? checkoutsRoot : checkoutsRoot + "/"
        guard standardizedPath.hasPrefix(prefix) else {
            return nil
        }
        return String(standardizedPath.dropFirst(prefix.count)).split(separator: "/").first.map(String.init)
    }

    private func orderedUnique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }
}

private struct ResolvedSwiftPackagePin {
    let identity: String
    let url: String
    let requirement: SwiftPackageRequirement
}

func remoteSwiftPackageRepositoryName(for url: String) -> String {
    "swiftpkg_\(packageIdentityName(for: packageName(from: url)))"
}

func packageIdentityName(for value: String) -> String {
    sanitizedModuleName(value.lowercased())
}

private func packageName(from url: String) -> String {
    let trimmed = url.hasSuffix(".git") ? String(url.dropLast(4)) : url
    return URL(string: trimmed)?.lastPathComponent
        ?? trimmed.split(separator: "/").last.map(String.init)
        ?? trimmed
}

private func comparablePackageName(_ value: String) -> String {
    value.lowercased().unicodeScalars
        .filter(CharacterSet.alphanumerics.contains)
        .map(String.init)
        .joined()
}
