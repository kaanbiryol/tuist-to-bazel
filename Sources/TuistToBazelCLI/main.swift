import ArgumentParser
import Foundation
import TuistToBazelCore

@main
struct TuistToBazelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tuist-to-bazel",
        abstract: "Generate Bazel files from a Tuist graph JSON.",
        subcommands: [Convert.self]
    )
}

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert a Tuist graph JSON into Bazel MODULE and BUILD files."
    )

    @Option(help: "Path to graph.json generated with `tuist graph --format json`.")
    var graph: String

    @Option(help: "Root directory of the Tuist project that produced the graph.")
    var root: String

    @Option(help: "Directory where Bazel files should be written.")
    var output: String

    @Flag(help: "Overwrite existing generated Bazel files.")
    var force = false

    func run() throws {
        let input = ConversionInput(
            graphPath: URL(fileURLWithPath: graph),
            rootPath: URL(fileURLWithPath: root),
            outputPath: URL(fileURLWithPath: output),
            force: force
        )

        let result = try Converter().convert(input)
        for warning in result.warnings {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }
        print("Generated \(result.writtenFiles.count) Bazel files.")
    }
}
