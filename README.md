# tuist-to-bazel

[![CI](https://github.com/kaanbiryol/tuist-to-bazel/actions/workflows/ci.yml/badge.svg)](https://github.com/kaanbiryol/tuist-to-bazel/actions/workflows/ci.yml)

`tuist-to-bazel` is a Swift command line tool that converts a Tuist graph JSON into Bazel module and BUILD files.

The converter intentionally decodes Tuist's graph with narrow local DTOs instead of depending on Tuist/XcodeGraph internals. The input contract is the JSON produced by `tuist graph`; the output is ordinary Bazel files that can be inspected, edited, and built directly.

See the [generated iOS application showcase](Examples/generated_ios_app_with_framework_and_resources) for a complete example of the converter's output.

## Requirements

- Swift 5.10+ / Xcode
- [Tuist](https://tuist.io) 4.169.2 (pinned and tested)
- [Bazelisk](https://github.com/bazelbuild/bazelisk)

## Build from source

The intended way to use `tuist-to-bazel` is from a source checkout that your team can inspect, pin, fork, and adapt to its migration needs. There is no separate global installation step.

```bash
git clone https://github.com/kaanbiryol/tuist-to-bazel.git
cd tuist-to-bazel
swift build -c release

.build/release/tuist-to-bazel --help
```

Keep the checkout at a known commit for repeatable migrations. If the generic conversion rules do not match your project, fork the repository and keep the project-specific changes in that fork.

## Quick Start

```bash
export TUIST_TO_BAZEL=/path/to/tuist-to-bazel/.build/release/tuist-to-bazel

cd /path/to/tuist/project
tuist graph -f json --no-open --output-path /tmp/tuist-graph

"$TUIST_TO_BAZEL" convert \
  --graph /tmp/tuist-graph/graph.json \
  --root /path/to/tuist/project \
  --output /path/to/tuist/project \
  --force

bazelisk build //...
```

The CLI writes:

- `.bazelignore` excluding Tuist's downloaded Swift package checkouts from Bazel package discovery
- `MODULE.bazel`
- root `BUILD.bazel` with a `rules_xcodeproj` target
- per-package `BUILD.bazel` files
- generated support sources under `.bazel/Generated`
- sanitized generated plist copies under `.bazel/InfoPlists` when needed

## Customizing the converter

The Swift package intentionally exposes the executable rather than a public library API. The source tree is the extension boundary:

- `Sources/TuistToBazelCLI/main.swift` defines the command-line interface.
- `Sources/TuistToBazelCore/TuistGraph.swift` and `TuistGraphParser.swift` define the narrow Tuist graph contract.
- `Sources/TuistToBazelCore/BazelGenerator*.swift` and the renderers define the generated Bazel model.

Run `swift test` after changing the conversion rules. Prefer small overrides that reflect real project needs; omitted Tuist features are not an implied compatibility backlog.

## Fixture Strategy

Tuist fixture coverage is intentionally bounded and pinned in `Fixtures/manifest.json`. Its 8 selected upstream fixtures are a frozen regression corpus for common Swift iOS and macOS project structures, supplemented by 2 small repository-owned fixtures for retained products that the upstream corpus does not isolate. The goal is not to mirror or eventually support every upstream Tuist fixture. The manifest records the upstream Tuist repository, commit, and selected fixture names. `scripts/update-tuist-fixtures.sh` uses git sparse checkout to refresh only those upstream `examples/xcode` fixtures in `Fixtures/Tuist`.

This repo intentionally does not use a git submodule for Tuist fixtures. The synced fixture corpus is committed as ordinary files, which keeps CI and local setup simple: clone this repo and the pinned fixtures are already present. Refreshing the frozen set is an explicit update step that produces normal reviewable diffs; it does not discover or add new Tuist fixtures.

The copied Tuist fixture corpus is third-party MIT-licensed test data. The pinned upstream commit and per-fixture source paths are recorded in `Fixtures/manifest.json`, each synced fixture receives a `.upstream.json`, and the upstream copyright notice is preserved in `NOTICE`.

Fixture directories have separate roles:

- `Examples/`: polished, fully supported showcases with generated Bazel output checked in.
- `Fixtures/Tuist/`: the fixed, curated upstream Tuist `examples/xcode` regression corpus used for migration conformance work.
- `Fixtures/Focused/`: minimal repository-owned projects for narrow retained-feature contracts.

The main example is checked in at `Examples/generated_ios_app_with_framework_and_resources`. It is sourced from Tuist's `examples/xcode/generated_ios_app_with_framework_and_resources` fixture at the manifest commit, then converted into a Bazel-compatible project.

### Choosing a fixture

For common dependency and platform questions, start with these fixtures:

| Scenario | Recommended fixture | What it covers |
|---|---|---|
| Swift packages | `generated_ios_app_with_remote_swift_package` | Remote package products and generated SwiftPM support files |
| Binary dependencies | `generated_ios_app_with_xcframeworks` | Dynamic and static XCFrameworks and linker settings |
| iOS and macOS | `generated_ios_app_with_tests` | Applications, frameworks, tests, and both retained platforms |
| Dynamic Swift libraries | `focused_ios_dynamic_library` | Direct `dynamicLibrary` conversion and build |
| Swift macros | `focused_macos_macro_plugin` | Macro target, compiler plugin, remote SwiftSyntax products, and a consuming framework |

The broader capability map is:

| Capability | Representative fixtures |
|---|---|
| Apps, frameworks, generic iOS extensions, and tests | `generated_app_with_framework_and_tests`, `generated_ios_app_with_tests` |
| Resources, bundles, localization, and string catalogs | `generated_ios_app_with_framework_and_resources`, `generated_ios_app_with_static_framework_with_xcstrings` |
| Static frameworks and direct binary imports | `generated_ios_app_with_static_framework_with_xcstrings`, `generated_ios_app_with_xcframeworks` |
| Remote Swift packages | `generated_app_with_alamofire`, `generated_ios_app_with_remote_swift_package` |
| Buildable folders and asset catalogs | `generated_ios_app_with_framework_buildable_folders_and_xcassets` |
| Dynamic libraries and macro compiler plugins | `focused_ios_dynamic_library`, `focused_macos_macro_plugin` |

The former upstream macro fixture is intentionally excluded because it primarily exercised local `Package.swift` translation and transitive mixed-language packages, both outside this tool's scope. The focused macro fixture covers the retained macro/compiler-plugin path without those unrelated features.

`Fixtures/manifest.json` contains the complete supported fixture set, feature tags, expected diagnostics, and verification commands.

### Verifying fixtures

Build the converter once, then pass any supported fixture name to the verifier:

```bash
swift build -c release
scripts/verify-tuist-fixtures.sh generated_ios_app_with_xcframeworks
```

The verifier copies the fixture to a temporary directory and runs its manifest-defined Tuist graph, conversion, Bazel query, build, and any configured test commands without modifying the checked-in fixture. For a faster build-only pass, omit simulator tests with `--skip-tests`. To verify the entire supported corpus, use `--all-supported`.

Refresh the checked-in Tuist fixtures with:

```bash
scripts/update-tuist-fixtures.sh
```

Set `TUIST_COMMIT=<sha>` to refresh from a different Tuist revision. The script preserves generated Bazel output in the showcase fixture and regenerates it when `tuist` is available locally.

The updater does three things:

- sparse-checks out only the selected upstream fixture directories from the pinned Tuist commit
- syncs the selected fixture set into `Fixtures/Tuist` and removes unselected local fixture directories
- refreshes the supported showcase under `Examples/`

It covers a fuller Tuist graph than the original small fixture:

- an iOS app and hosted iOS unit test target
- a dynamic framework
- static frameworks
- resource bundle targets
- direct framework resources
- asset catalogs, localized strings, string dictionaries, plists, fonts, folder references, and `.bundle` imports
- Tuist-style synthesized resource accessors generated as Swift support sources

Some fixtures intentionally include binary-style test payloads such as XCFrameworks, image assets, and resource bundles. They are not production dependencies for `tuist-to-bazel`; they are committed conformance inputs so XCFramework import, asset catalog, bundle import, and framework-resource generation stay reproducible in CI. The `SF-Pro-Display-*.otf` files in the copied fixtures and showcase are filename-only placeholders generated by the updater script, not redistributions of Apple's font payloads.

Useful verification commands:

```bash
swift test
cd Examples/generated_ios_app_with_framework_and_resources
bazelisk query //...
bazelisk build //...
```

## Supported Generation

| Tuist product | Bazel output |
|---|---|
| `app` | `swift_library` + iOS or macOS application rule |
| `appExtension` / `app_extension` | `swift_library` + generic `ios_extension` |
| `framework` | `swift_library` + iOS or macOS framework rule |
| `staticFramework` / `static_framework` | `swift_library` + iOS or macOS static framework rule |
| `bundle` | `apple_resource_bundle` |
| `unitTests` / `unit_tests` | `swift_library` + iOS or macOS unit test rule |
| `uiTests` / `ui_tests` | `swift_library` + iOS or macOS UI test rule |
| `staticLibrary` / `dynamicLibrary` | `swift_library` |
| `macro` | `swift_compiler_plugin` |

Source targets must contain Swift only and generate `swift_library`. Their base `SWIFT_VERSION` setting is preserved as the corresponding Swift language mode (for example, Xcode's `6.1` value becomes `-swift-version 6`). Objective-C, C, C++, headers, and mixed-language targets fail conversion with an actionable diagnostic.

Dependency generation includes:

- target and project dependencies with iOS and macOS platform conditions
- remote Swift package products and compiler plugins; Tuist checkout projects backed by `Package.resolved` are delegated to `rules_swift_package_manager`
- SDK frameworks, weak SDK frameworks, SDK libraries, and XCTest
- direct static or dynamic XCFramework imports

Resource handling includes `apple_resource_group`, `apple_bundle_import` for checked-in `.bundle` directories, generated `Bundle.module` bridges including for string catalogs, and narrow Tuist-style accessors for assets, strings, string dictionaries, plists, and fonts.

`Fixtures/manifest.json` is the fixture support contract. Every selected entry is supported and has executable graph, conversion, query, and build plans. Features omitted from the corpus are not an implied roadmap.

## Current Limits

- The graph DTOs cover only the fields needed for Bazel generation.
- Package products that cannot be mapped unambiguously are reported as warnings. Remote packages require `Package.resolved`.
- Local `Package.swift` translation is unsupported; migrate local packages to Bazel separately.
- Checked-in `.framework` bundles and `.a` archives are unsupported; package binaries as XCFrameworks.
- Core Data models and generated entity classes are unsupported.
- Remote package compatibility is bounded by `rules_swift_package_manager`; their downloaded Tuist checkout sources are not translated as local targets. Packages that use deprecated transitive by-name product references may need an [upstream package patch](https://github.com/cgrindel/rules_swift_package_manager/blob/main/docs/faq.md#how-do-i-handle-the-error-unable-to-resolve-byname-reference-xxx-in-swiftpkg_yyy).
- App Clips, specialized extension products, and targets exclusive to tvOS, watchOS, or visionOS are unsupported. Cross-platform dependencies generate only their iOS or macOS slice.
- Objective-C, C, C++, headers, and mixed-language targets are unsupported.
- ODR resource tags are reported as warnings and are not represented in Bazel output.
- Resource accessor synthesis is intentionally narrow and aimed at common Tuist-generated symbols.
- Minimum OS versions are currently fixed at iOS 17.0 and macOS 14.0.
- Command-line tools and Swift package registries are outside the intended migration scope.
- Apart from the Swift language version and narrow plist/version settings, arbitrary build settings, scripts, and custom Tuist build rules are not modeled.
- XCTest bundles are generated and built, but simulator execution on Xcode 26.6 is not a CI gate because the test runner pinned by stable rules_apple 4.5.x can hang before launching tests.

## License

MIT
