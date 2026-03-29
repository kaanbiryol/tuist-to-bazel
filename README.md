# tuist-to-bazel

Generates Bazel BUILD files from a Tuist project graph. Parses `tuist graph -f json` output and produces `MODULE.bazel`, root `BUILD.bazel`, and per-target `BUILD.bazel` files with the correct `rules_apple`/`rules_swift` rules.

## Why

Migrating an iOS project from Tuist to Bazel requires manually translating every target, dependency, and build setting into BUILD files. This tool automates the scaffolding - you get a buildable Bazel project from your existing Tuist graph in seconds.

## What it does

- Reads the XcodeGraph JSON format from `tuist graph`
- Resolves internal targets, SPM packages, and local xcframeworks into Bazel labels
- Generates `ios_application`, `ios_extension`, or `swift_library` rules per product type
- Produces `MODULE.bazel` with pinned rule versions (rules_apple 4.5.2, rules_swift 3.5.0, rules_xcodeproj 4.0.0)
- Generates root `BUILD.bazel` with `xcodeproj` and Gazelle integration (when SPM deps are present)
- Skips test targets automatically

## Requirements

- Ruby (any recent version, no gems)
- [Tuist](https://tuist.io) 4.169.2+
- [Bazelisk](https://github.com/bazelbuild/bazelisk) (`brew install bazelisk`)

## Quick start

```bash
cd your-tuist-project
tuist graph -f json --no-open
ruby /path/to/tuist-to-bazel/Sources/bazel.rb graph.json
bazel build //...
```

## Usage

```bash
# Without SPM dependencies
ruby Sources/bazel.rb graph.json

# With SPM dependencies
ruby Sources/bazel.rb graph.json Tuist/Package.swift
```

Generated files:
- `MODULE.bazel` - Bazel module with rule versions
- `BUILD.bazel` - Root build file (xcodeproj, schemes, optional Gazelle)
- `<Target>/BUILD.bazel` - Per-target build rules
- `vendor/BUILD.bazel` - Local xcframework imports (if any)

### Testing with the fixture

```bash
cd test_fixture
tuist graph -f json --no-open
ruby ../Sources/bazel.rb graph.json
bazel build //...
```

## How it works

1. Parses the dependency DAG and project structure from Tuist's XcodeGraph JSON
2. Resolves dependencies into Bazel labels (internal targets, SPM packages via `swift_deps_index.json`, xcframeworks)
3. Generates the appropriate Bazel rule per product type with correct dependency wiring

## Supported product types

| Tuist product | Bazel rule | Status |
|---|---|---|
| `app` | `ios_application` + `swift_library` | Supported |
| `app_extension` | `ios_extension` + `swift_library` | Supported |
| `framework` / `staticFramework` | `swift_library` + `ios_build_test` | Supported |
| `staticLibrary` / `dynamicLibrary` | `swift_library` + `ios_build_test` | Supported |
| `unitTests` / `uiTests` | - | Skipped |
| `appClip` | `ios_app_clip` | Not yet supported |
| `watch2App` / `watch2Extension` | `watchos_application` / `watchos_extension` | Not yet supported |
| `tvTopShelfExtension` | `tvos_extension` | Not yet supported |
| `messagesExtension` | `ios_imessage_extension` | Not yet supported |
| `stickerPackExtension` | `ios_sticker_pack_extension` | Not yet supported |
| `extensionKitExtension` | `ios_extension` | Not yet supported |
| `commandLineTool` | `swift_binary` | Not yet supported |
| `bundle` / `macro` / `xpc` / `systemExtension` | - | Not yet supported |

Unsupported types fall back to `swift_library` + `ios_build_test`.

## Limitations

- Hardcoded minimum iOS version (17.0), scheme names, and project name
- No Objective-C or mixed-language target support
- SPM dependency resolution requires running `bazel run //:update_swift_packages` after generation
- May require manual fixes for conflicting package names, transitive dependencies, or non-standard xcframework paths
- Single-project graphs only (multi-project workspaces untested)

## License

MIT
