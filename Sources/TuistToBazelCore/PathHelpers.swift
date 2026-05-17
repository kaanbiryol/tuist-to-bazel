import Foundation

struct PathContext {
    let root: URL
    let output: URL

    func packagePath(for absolutePath: String) throws -> String {
        try relativePath(absolutePath, from: root)
    }

    func outputDirectory(for packagePath: String) -> URL {
        packagePath.isEmpty ? output : output.appendingPathComponent(packagePath, isDirectory: true)
    }

    func relativePath(_ absolutePath: String, from base: URL) throws -> String {
        let value = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let basePath = base.standardizedFileURL.path
        if value == basePath {
            return ""
        }
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard value.hasPrefix(prefix) else {
            throw ConversionError.pathOutsideRoot(value)
        }
        return String(value.dropFirst(prefix.count))
    }

    func pathRelativeToPackage(_ absolutePath: String, packagePath: String) throws -> String {
        let packageRoot = packagePath.isEmpty ? root : root.appendingPathComponent(packagePath, isDirectory: true)
        return try relativePath(absolutePath, from: packageRoot)
    }
}
