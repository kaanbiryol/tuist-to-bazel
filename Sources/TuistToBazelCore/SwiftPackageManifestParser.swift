import Foundation

struct SwiftPackageManifest {
    let packagePath: String
    let products: [SwiftPackageProduct]
    let targets: [SwiftPackageTarget]
}

struct SwiftPackageProduct {
    let name: String
    let targets: [String]
}

struct SwiftPackageTarget {
    let name: String
    let sources: [String]
    let dependencies: [String]
}

struct SwiftPackageManifestParser {
    private let fileManager = FileManager.default

    func parse(packagePath: String) throws -> SwiftPackageManifest {
        let packageURL = URL(fileURLWithPath: packagePath)
        let manifestURL = packageURL.appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        let sourceTargetNames = try sourceTargetNames(in: packageURL)
        let declaredTargets = parseDeclaredTargets(in: manifest)
        let targetNames = orderedUnique(declaredTargets.map(\.name) + sourceTargetNames)
        let declaredByName = Dictionary(uniqueKeysWithValues: declaredTargets.map { ($0.name, $0) })
        let targets = try targetNames.map { name in
            SwiftPackageTarget(
                name: name,
                sources: try sourceFiles(for: name, in: packageURL),
                dependencies: declaredByName[name]?.dependencies ?? []
            )
        }

        let products = parseLibraryProducts(in: manifest)
        return SwiftPackageManifest(
            packagePath: packagePath,
            products: products.isEmpty ? targets.map { SwiftPackageProduct(name: $0.name, targets: [$0.name]) } : products,
            targets: targets
        )
    }

    private func parseLibraryProducts(in manifest: String) -> [SwiftPackageProduct] {
        captures(pattern: #"\.library\s*\((.*?)\)"#, in: manifest).compactMap { body in
            guard let name = firstCapture(pattern: #"name:\s*"([^"]+)""#, in: body) else {
                return nil
            }
            let targets = firstCapture(pattern: #"targets:\s*\[([^\]]*)\]"#, in: body)
                .map(quotedStrings(in:)) ?? [name]
            return SwiftPackageProduct(name: name, targets: targets)
        }
    }

    private func parseDeclaredTargets(in manifest: String) -> [SwiftPackageTarget] {
        captures(pattern: #"\.target\s*\((.*?)\)"#, in: manifest).compactMap { body in
            guard let name = firstCapture(pattern: #"name:\s*"([^"]+)""#, in: body) else {
                return nil
            }
            return SwiftPackageTarget(
                name: name,
                sources: [],
                dependencies: firstCapture(pattern: #"dependencies:\s*\[([^\]]*)\]"#, in: body)
                    .map(quotedStrings(in:)) ?? []
            )
        }
    }

    private func sourceTargetNames(in packageURL: URL) throws -> [String] {
        let sourcesURL = packageURL.appendingPathComponent("Sources", isDirectory: true)
        guard fileManager.fileExists(atPath: sourcesURL.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: sourcesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .map(\.lastPathComponent)
        .sorted()
    }

    private func sourceFiles(for targetName: String, in packageURL: URL) throws -> [String] {
        let targetURL = packageURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: targetURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            files.append(url.path)
        }
        return files.sorted()
    }

    private func firstCapture(pattern: String, in value: String) -> String? {
        captures(pattern: pattern, in: value).first
    }

    private func captures(pattern: String, in value: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
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

    private func quotedStrings(in value: String) -> [String] {
        captures(pattern: #""([^"]+)""#, in: value)
    }

    private func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
