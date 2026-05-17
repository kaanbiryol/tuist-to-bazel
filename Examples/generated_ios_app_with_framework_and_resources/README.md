# iOS app with a framework and resources

A workspace with an application that includes resources.

This fixture is copied from `tuist/tuist` at commit `2be1eb0076143ebc60e86fff7b5c334c0808baa3` and checked in here as the primary Bazel conversion showcase.

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
