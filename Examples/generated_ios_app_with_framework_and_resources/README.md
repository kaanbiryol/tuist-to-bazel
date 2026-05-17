# iOS app with a framework and resources

A workspace with an application that includes resources.

This fixture is sourced from `tuist/tuist` at the commit recorded in `.upstream.json` and checked in here as the primary Bazel conversion showcase. Refresh it from the repo root with:

```bash
scripts/update-tuist-fixtures.sh
```

The `SF-Pro-Display-*.otf` files are lightweight placeholders. The converter only needs those resource filenames to generate the font accessors used by this showcase.

```
Workspace:
  - App:
    - MainApp (iOS app)
    - MainAppTests (iOS unit tests)
  - Framework1:
    - Framework1 (dynamic iOS framework)
  - StaticFramework
    - StaticFramework (static iOS framework)
    - StaticFrameworkResources (iOS bundle)
  - StaticFramework2
    - StaticFramework2 (static iOS framework)
    - StaticFramework2Resources (iOS bundle)
  - StaticFramework3:
    - StaticFramework3 (static iOS framework with direct resources)
  - StaticFramework4:
    - StaticFramework4 (static iOS framework with synthesized resource accessors)
  - StaticFramework5:
    - StaticFramework5 (resource-only static framework)
```

Dependencies:

- App -> Framework1
- App -> StaticFramework
- App -> StaticFrameworkResources
- App -> StaticFramework2
- App -> StaticFramework3
- App -> StaticFramework4
- App -> StaticFramework5

Generated Bazel files are committed next to the Tuist files. From this directory:

```bash
bazelisk query //...
bazelisk build //...
```
