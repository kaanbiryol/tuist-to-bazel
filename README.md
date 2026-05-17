# tuist-to-bazel

`tuist-to-bazel` is a Swift command line tool that converts a Tuist graph JSON into Bazel module and BUILD files.

The converter intentionally decodes Tuist's graph with narrow local DTOs instead of depending on Tuist/XcodeGraph internals. The input contract is the JSON produced by `tuist graph`; the output is ordinary Bazel files that can be inspected, edited, and built directly.

## Requirements

- Swift 5.10+ / Xcode
- [Tuist](https://tuist.io) 4.169.2+
- [Bazelisk](https://github.com/bazelbuild/bazelisk)

## Quick Start

```bash
cd /path/to/tuist/project
tuist graph -f json --no-open --output-path /tmp/tuist-graph

swift run --package-path /path/to/tuist-to-bazel tuist-to-bazel convert \
  --graph /tmp/tuist-graph/graph.json \
  --root /path/to/tuist/project \
  --output /path/to/tuist/project \
  --force

bazelisk build //...
```

The CLI writes:

- `MODULE.bazel`
- root `BUILD.bazel` with a `rules_xcodeproj` target
- per-package `BUILD.bazel` files
- generated support sources under `.bazel/Generated`
- sanitized generated plist copies under `.bazel/InfoPlists` when needed

## Showcase Fixture

The main example is checked in at `Examples/generated_ios_app_with_framework_and_resources`. It is copied from Tuist's `examples/xcode/generated_ios_app_with_framework_and_resources` fixture and converted into a Bazel-compatible project.

It covers a fuller Tuist graph than the original small fixture:

- an iOS app and hosted iOS unit test target
- a dynamic framework
- static frameworks
- resource bundle targets
- direct framework resources
- asset catalogs, localized strings, string dictionaries, plists, fonts, folder references, and `.bundle` imports
- Tuist-style synthesized resource accessors generated as Swift support sources

Useful verification commands:

```bash
swift test
cd Examples/generated_ios_app_with_framework_and_resources
bazelisk query //...
bazelisk build //...
```

`bazelisk test //App:AppTests` currently builds the test bundle but the local simulator runner exits with status 15 in this environment immediately after creating the simulator, before XCTest output is produced.

## Supported Generation

| Tuist product | Bazel output |
|---|---|
| `app` | `swift_library` + `ios_application` |
| `appExtension` / `app_extension` | `swift_library` + `ios_extension` |
| `framework` | `swift_library` + `ios_framework` |
| `staticFramework` / `static_framework` | `swift_library` + `ios_static_framework` |
| `bundle` | `apple_resource_bundle` |
| `unitTests` / `unit_tests` | `swift_library` + `ios_unit_test` |
| `staticLibrary` / `dynamicLibrary` | `swift_library` |

Resource handling includes `apple_resource_group`, `apple_bundle_import` for checked-in `.bundle` directories, generated `Bundle.module` bridges, and narrow Tuist-style accessors for assets, strings, string dictionaries, plists, and fonts.

## Current Limits

- The graph DTOs cover only the fields needed for Bazel generation.
- External package, SDK, framework, xcframework, and library dependencies are decoded but not fully generated yet.
- ODR resource tags are reported as warnings and are not represented in Bazel output.
- Resource accessor synthesis is intentionally narrow and aimed at common Tuist-generated symbols.
- The generated minimum iOS version is currently `17.0`.
- UI test target generation is decoded but not implemented.
- Objective-C, C, mixed-language targets, build settings, scripts, and custom Tuist build rules are not modeled yet.

## License

MIT
