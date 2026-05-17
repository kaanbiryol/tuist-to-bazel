import Foundation

public struct ConversionInput {
    public let graphPath: URL
    public let rootPath: URL
    public let outputPath: URL
    public let force: Bool

    public init(graphPath: URL, rootPath: URL, outputPath: URL, force: Bool) {
        self.graphPath = graphPath.standardizedFileURL
        self.rootPath = rootPath.standardizedFileURL
        self.outputPath = outputPath.standardizedFileURL
        self.force = force
    }
}

public struct ConversionResult {
    public let writtenFiles: [URL]
    public let warnings: [String]
}

public enum ConversionError: Error, CustomStringConvertible {
    case invalidGraph(String)
    case pathOutsideRoot(String)
    case outputExists(URL)
    case unsupported(String)

    public var description: String {
        switch self {
        case let .invalidGraph(message):
            "Invalid graph JSON: \(message)"
        case let .pathOutsideRoot(path):
            "Path is outside the project root: \(path)"
        case let .outputExists(url):
            "Refusing to overwrite existing file without --force: \(url.path)"
        case let .unsupported(message):
            "Unsupported graph feature: \(message)"
        }
    }
}
