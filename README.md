# tuist-to-bazel

Converts a Tuist project graph into Bazel BUILD files. Reads the JSON output of `tuist graph` and generates `MODULE.bazel`, root `BUILD.bazel`, and per-target `BUILD.bazel` files with `swift_library` and `ios_build_test` rules.

## Prerequisites

- Ruby (any recent version, no gems required)
- [Tuist](https://tuist.io) 4.169.2+
- [Bazelisk](https://github.com/bazelbuild/bazelisk) (`brew install bazelisk`)

## Usage

### 1. Generate the Tuist graph

```bash
cd /path/to/your/tuist/project
tuist graph -f json --no-open
```

This produces a `graph.json` file in the current directory.

### 2. Run the tool

```bash
ruby /path/to/tuist-to-bazel/Sources/bazel.rb graph.json
```

If your project has SPM dependencies via `Tuist/Package.swift`:

```bash
ruby /path/to/tuist-to-bazel/Sources/bazel.rb graph.json Tuist/Package.swift
```

This generates:
- `MODULE.bazel` - Bazel module with pinned rule versions
- `BUILD.bazel` - Root build file with xcodeproj, gazelle, and schemes
- `<Target>/BUILD.bazel` - Per-target build files with `swift_library` and `ios_build_test`
- `vendor/BUILD.bazel` - Local xcframework imports (if any)

### 3. Build with Bazel

```bash
# Build everything
bazel build //...

# Build a specific target
bazel build //App:App

# Run the iOS build test
bazel build //App:_App
```

### 4. Generate Xcode project (optional)

```bash
bazel run //:xcodeproj
```

### 5. Update SPM dependencies (optional)

```bash
bazel run //:update_swift_packages
```

## Testing with the fixture

A test fixture from the Tuist repo is included at `test_fixture/`:

```bash
cd test_fixture
tuist graph -f json --no-open
ruby ../Sources/bazel.rb graph.json
bazel build //...
```

## How it works

1. Parses the XcodeGraph JSON format from `tuist graph -f json`
2. Iterates over local (non-external) projects and their targets
3. Skips test targets and SwiftLint targets
4. Resolves three types of dependencies:
   - Internal targets - mapped to Bazel labels (e.g., `//Framework:Framework`)
   - SPM packages - mapped via `swift_deps_index.json` (e.g., `@swiftpkg_nuke//:Nuke`)
   - Local xcframeworks - mapped to `apple_static_xcframework_import` rules
5. Generates BUILD files with `swift_library` for each target

## Post-generation manual fixes

Bazel requires every dependency to be declared explicitly. You may need to manually fix:

- Dependency renames for packages with conflicting names (e.g., Phrase/Adjust both using `ios_sdk`)
- Additional MODULE.bazel entries for transitive dependencies
- Vendor BUILD file adjustments for xcframeworks with non-standard paths
