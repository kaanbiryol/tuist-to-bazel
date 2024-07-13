## Install Bazelisk

- `brew install bazelisk`

## Generate tuist graph

- `tuist install` (make sure to have the latest dependencies)
- `tuist graph -f json`

## Move Package.swift

`mv Tuist/Package.swift Package.swift`. This is required to generate files for third party libraries.

## (Optional) update third party depenencies

- `bazel run //:swift_update_pkgs`

# Edit 

Bazel requires every dependency to be declared explicitly to ensure hermetic builds. Since we don't have explicit dependencies in our Project.swift, you are going to have to manually fix the missing dependencies in the build graph.

1. Change `swiftpkg_ios_sdk` for Phrase to `swiftpkg_phrase` in MODULE.bazel and swift_deps_index.json.

2. Add   
```
"swiftpkg_swift_nio_ssl",
"swiftpkg_adyen_networking_ios"
```
to MODULE.bazel

3. Fix vendor/build.bazel

```
    load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")

apple_static_xcframework_import(
    name = "IncdOnboarding",
    xcframework_imports = glob(["Incode/IncdOnboarding.xcframework/**"]),
    visibility = ["//visibility:public"],
)

apple_static_xcframework_import(
    name = "opencv2",
    xcframework_imports = glob(["Incode/opencv2.xcframework/**"]),
    visibility = ["//visibility:public"],
)

apple_static_xcframework_import(
    name = "SXPayment",
    xcframework_imports = glob(["SXPayment.xcframework/**"]),
    visibility = ["//visibility:public"],
)

apple_static_xcframework_import(
    name = "DBDebugToolkitSDK",
    xcframework_imports = glob(["DBDebugToolkit.xcframework/**"]),
    visibility = ["//visibility:public"],
)

apple_static_xcframework_import(
    name = "MarketingCloudSDK",
    xcframework_imports = glob(["MarketingCloudSDK.xcframework/**"]),
    visibility = ["//visibility:public"],
)
```
## Run the tool

- `ruby tuist-to-bazel/bazel.rb graph.json swift_deps_index.json`

## Edit the swift_deps_index.json for Phrase

 - Change `swiftpkg_ios_sdk` label to `swiftpkg_phrase` in necessary parts. (This is required because `rules_spm` resolves the name of the Git repository and Phrase and Adjust are both using `ios_sdk` as their repository name.) 
 - [ ] See if there is a way to set a name either in `Package.swift` or `rules_spm` for this. Otherwise, create an issue in `rules_spm`. 

## Generate Xcode project

- `bazel run //:xcodeproj`

## (Optional) build app

- `bazel build //apps/App/Sources:app --swiftcopt=-suppress-warnings`  


