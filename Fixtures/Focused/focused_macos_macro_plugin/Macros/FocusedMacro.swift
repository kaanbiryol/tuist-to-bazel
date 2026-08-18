import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct FortyTwoMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        "42"
    }
}

@main
struct FocusedCompilerPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        FortyTwoMacro.self,
    ]
}
