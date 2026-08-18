import ProjectDescription

let project = Project(
    name: "FocusedMacroPlugin",
    packages: [
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            .exact("603.0.2")
        ),
    ],
    targets: [
        .target(
            name: "FocusedMacros",
            destinations: .macOS,
            product: .macro,
            bundleId: "dev.tuist.focused.macros",
            sources: "Macros/**",
            dependencies: [
                .package(product: "SwiftCompilerPlugin"),
                .package(product: "SwiftSyntax"),
                .package(product: "SwiftSyntaxMacros"),
            ]
        ),
        .target(
            name: "MacroClient",
            destinations: .macOS,
            product: .framework,
            bundleId: "dev.tuist.focused.macro-client",
            sources: "Client/**",
            dependencies: [
                .target(name: "FocusedMacros"),
            ]
        ),
    ]
)
