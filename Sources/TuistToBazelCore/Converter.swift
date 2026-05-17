import Foundation

public struct Converter {
    public init() {}

    public func convert(_ input: ConversionInput) throws -> ConversionResult {
        let data = try Data(contentsOf: input.graphPath)
        let graph = try TuistGraphParser().parse(data: data)
        let paths = PathContext(root: input.rootPath, output: input.outputPath)
        var generator = BazelGenerator(graph: graph, paths: paths)
        let rendered = try generator.render()

        var written: [URL] = []
        for relativePath in rendered.files.keys.sorted() {
            let outputURL = input.outputPath.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: outputURL.path), !input.force {
                throw ConversionError.outputExists(outputURL)
            }
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try rendered.files[relativePath]?.write(to: outputURL, atomically: true, encoding: .utf8)
            written.append(outputURL)
        }

        return ConversionResult(writtenFiles: written, warnings: rendered.warnings)
    }
}
