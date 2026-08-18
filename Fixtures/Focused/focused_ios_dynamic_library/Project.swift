import ProjectDescription

let project = Project(
    name: "FocusedDynamicLibrary",
    targets: [
        .target(
            name: "DynamicLibrary",
            destinations: .iOS,
            product: .dynamicLibrary,
            bundleId: "dev.tuist.focused.dynamic-library",
            sources: "Sources/**"
        ),
    ]
)
