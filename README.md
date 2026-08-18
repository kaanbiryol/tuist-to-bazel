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

Tuist fixture coverage is intentionally bounded and pinned in `Fixtures/manifest.json`. Its 25 selected fixtures are a frozen regression corpus for common project structures, primarily generic iOS application migrations; the goal is not to mirror or eventually support every upstream Tuist fixture. The manifest records the upstream Tuist repository, commit, and selected fixture names. `scripts/update-tuist-fixtures.sh` uses git sparse checkout to refresh only those upstream `examples/xcode` fixtures in `Fixtures/Tuist`.

This repo intentionally does not use a git submodule for Tuist fixtures. The synced fixture corpus is committed as ordinary files, which keeps CI and local setup simple: clone this repo and the pinned fixtures are already present. Refreshing the frozen set is an explicit update step that produces normal reviewable diffs; it does not discover or add new Tuist fixtures.

The copied Tuist fixture corpus is third-party MIT-licensed test data. The pinned upstream commit and per-fixture source paths are recorded in `Fixtures/manifest.json`, each synced fixture receives a `.upstream.json`, and the upstream copyright notice is preserved in `NOTICE`.

Fixture directories have separate roles:

- `Examples/`: polished, fully supported showcases with generated Bazel output checked in.
- `Fixtures/Tuist/`: the fixed, curated upstream Tuist `examples/xcode` regression corpus used for migration conformance work.

The main example is checked in at `Examples/generated_ios_app_with_framework_and_resources`. It is sourced from Tuist's `examples/xcode/generated_ios_app_with_framework_and_resources` fixture at the manifest commit, then converted into a Bazel-compatible project.

### Choosing a fixture

For common dependency and platform questions, start with these fixtures:

| Scenario | Recommended fixture | What it covers |
|---|---|---|
| Swift packages | `generated_app_with_local_spm_module_with_remote_dependencies` | Local package products with transitive remote dependencies |
| Binary dependencies | `generated_ios_app_with_xcframeworks` | Dynamic and static XCFrameworks, static libraries, and linker settings |
| Multiple platforms | `generated_multiplatform_app` | iOS, macOS, watchOS, and platform-conditional dependencies |

The broader capability map is:

| Capability | Representative fixtures |
|---|---|
| Apps, frameworks, extensions, and unit tests | `generated_app_with_framework_and_tests`, `generated_ios_app_with_tests` |
| Resources, bundles, localization, and string catalogs | `generated_ios_app_with_framework_and_resources`, `generated_ios_app_with_static_framework_with_xcstrings` |
| Static frameworks, libraries, and binary imports | `generated_ios_app_with_static_frameworks_with_resources`, `generated_ios_app_with_static_libraries`, `generated_ios_app_with_xcframeworks` |
| SDKs, weak linking, headers, and mixed-language targets | `generated_ios_app_with_sdk`, `generated_ios_app_with_headers` |
| Local, remote, and binary Swift packages | `generated_ios_app_with_local_swift_package`, `generated_ios_app_with_remote_swift_package`, `generated_ios_app_with_local_binary_swift_package` |
| App Clips and extension products | `generated_ios_app_with_appclip`, `generated_ios_app_with_extensions` |
| Core Data and buildable folders | `generated_ios_app_with_coredata`, `generated_ios_app_with_framework_buildable_folders_and_xcassets` |
| watchOS, tvOS, and visionOS products | `generated_ios_app_with_watch_application`, `generated_tvos_app_with_extensions`, `generated_tvos_app_with_uitest`, `generated_visionos_app` |
| Multiplatform conditional dependencies | `generated_multiplatform_app` |

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

Some fixtures intentionally include binary-style test payloads such as small prebuilt frameworks, archives, image assets, and resource bundles. They are not production dependencies for `tuist-to-bazel`; they are committed conformance inputs so binary import, asset catalog, bundle import, and framework-resource generation stay reproducible in CI. The `SF-Pro-Display-*.otf` files in the copied fixtures and showcase are filename-only placeholders generated by the updater script, not redistributions of Apple's font payloads.

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
| `app` | source library + iOS, tvOS, watchOS, or visionOS application rule |
| `appClip` / `app_clip` | `swift_library` + `ios_app_clip` |
| `appExtension` / `app_extension` | source library + iOS, macOS, tvOS, or watchOS extension rule |
| `extensionKitExtension`, Messages, sticker pack, and TV top shelf extensions | source library + matching platform extension rule |
| `framework` | source library + platform framework rule |
| `staticFramework` / `static_framework` | source library + platform static framework rule |
| `bundle` | `apple_resource_bundle` |
| `unitTests` / `unit_tests` | `swift_library` + platform unit test rule |
| `uiTests` / `ui_tests` | `swift_library` + platform UI test rule |
| `staticLibrary` / `dynamicLibrary` | source library |
| `macro` | `swift_compiler_plugin` |

Source targets generate `swift_library`, `objc_library`, or `mixed_language_library` as appropriate. Supported Clang inputs include C, C++, Objective-C, Objective-C++, and Tuist header groups.

Dependency generation includes:

- target and project dependencies with platform conditions
- local and remote Swift package products, including local binary targets and compiler plugins
- SDK frameworks, weak SDK frameworks, SDK libraries, and XCTest
- checked-in frameworks, static archives with Swift module maps, and static or dynamic XCFramework imports

Resource handling includes `apple_resource_group`, `apple_bundle_import` for checked-in `.bundle` directories, `apple_core_data_model` for Core Data generated sources, generated `Bundle.module` bridges including for string catalogs, and narrow Tuist-style accessors for assets, strings, string dictionaries, plists, fonts, and Core Data entity classes.

`Fixtures/manifest.json` is the fixture support contract. Every selected entry is supported and has executable graph, conversion, query, and build plans. Features omitted from the corpus are not an implied roadmap.

## Current Limits

- The graph DTOs cover only the fields needed for Bazel generation.
- Package products that cannot be mapped unambiguously are reported as warnings. Remote packages require `Package.resolved`.
- Binary libraries without a Swift module map are reported as warnings rather than generated.
- ODR resource tags are reported as warnings and are not represented in Bazel output.
- Resource accessor synthesis is intentionally narrow and aimed at common Tuist-generated symbols.
- Minimum OS versions are currently fixed at iOS/tvOS 17.0, macOS 14.0, watchOS 9.0, and visionOS 1.0.
- Standalone macOS applications, visionOS extensions, command-line tools, and Swift package registries are outside the intended generic iOS migration scope and are not tracked as planned fixtures.
- Arbitrary build settings, scripts, and custom Tuist build rules are not modeled.
- XCTest bundles are generated and built, but simulator execution on Xcode 26.6 is not a CI gate because the test runner pinned by stable rules_apple 4.5.x can hang before launching tests.

## License

MIT
