import XCTest
@testable import TuistToBazelCore

final class TuistGraphParserTests: XCTestCase {
    func testParsesAlternatingProjectsArray() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": [
            "/tmp/App",
            {
              "name": "App",
              "targets": {
                "App": {
                  "product": "app",
                  "destinations": ["iPhone", "iPad"],
                  "bundleId": "dev.tuist.App",
                  "productName": "App",
                  "infoPlist": { "file": { "path": "/tmp/App/Info.plist" } },
                  "sources": [{ "path": "/tmp/App/Sources/App.swift" }],
                  "resources": {
                    "resources": [
                      { "file": { "path": "/tmp/App/Resources/Assets.xcassets", "tags": [] } },
                      { "folderReference": { "path": "/tmp/App/Examples", "tags": ["tag1"] } }
                    ]
                  },
                  "dependencies": [
                    { "target": { "name": "Framework", "status": "required" } }
                  ]
                }
              }
            }
          ]
        }
        """

        let graph = try TuistGraphParser().parse(data: Data(json.utf8))

        XCTAssertEqual(graph.name, "Fixture")
        XCTAssertEqual(graph.projects.count, 1)
        XCTAssertEqual(graph.projects[0].targets[0].name, "App")
        XCTAssertEqual(graph.projects[0].targets[0].product, .app)
        XCTAssertEqual(graph.projects[0].targets[0].destinations, ["iPhone", "iPad"])
        XCTAssertEqual(graph.projects[0].targets[0].resources.count, 2)
        XCTAssertEqual(graph.projects[0].targets[0].dependencies.count, 1)
    }

    func testRecordsLocalSwiftPackagesForUnsupportedFeatureDiagnostics() throws {
        let json = """
        {
          "name": "Fixture",
          "packages": [
            "/tmp/App",
            {
              "/tmp/App/Packages/PackageA": {
                "local": {
                  "path": "/tmp/App/Packages/PackageA"
                }
              }
            },
            "/tmp/App/Framework",
            {
              "/tmp/App/Packages/PackageA": {
                "local": {
                  "path": "/tmp/App/Packages/PackageA"
                }
              }
            }
          ],
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {}
            }
          }
        }
        """

        let graph = try TuistGraphParser().parse(data: Data(json.utf8))

        XCTAssertEqual(graph.localSwiftPackagePaths, ["/tmp/App/Packages/PackageA"])
    }

    func testParsesRemoteSwiftPackages() throws {
        let json = """
        {
          "name": "Fixture",
          "packages": [
            "/tmp/App",
            {
              "https://github.com/ReactiveX/RxSwift": {
                "remote": {
                  "url": "https://github.com/ReactiveX/RxSwift",
                  "requirement": {
                    "upToNextMajor": {
                      "_0": "5.0.0"
                    }
                  }
                }
              }
            }
          ],
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {}
            }
          }
        }
        """

        let graph = try TuistGraphParser().parse(data: Data(json.utf8))

        XCTAssertEqual(
            graph.remoteSwiftPackages,
            [TuistRemoteSwiftPackage(url: "https://github.com/ReactiveX/RxSwift", requirement: .upToNextMajor("5.0.0"))]
        )
        XCTAssertEqual(
            graph.remoteSwiftPackagesByProjectPath["/tmp/App"],
            [TuistRemoteSwiftPackage(url: "https://github.com/ReactiveX/RxSwift", requirement: .upToNextMajor("5.0.0"))]
        )
    }

    func testParsesPackagePluginDependencies() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "Framework": {
                  "product": "framework",
                  "dependencies": [
                    {
                      "package": {
                        "product": "SwiftLint",
                        "type": "plugin package product"
                      }
                    }
                  ]
                }
              }
            }
          }
        }
        """

        let graph = try TuistGraphParser().parse(data: Data(json.utf8))
        let dependency = try XCTUnwrap(graph.projects.first?.targets.first?.dependencies.first)

        guard case let .package(product, kind) = dependency else {
            return XCTFail("expected package dependency")
        }
        XCTAssertEqual(product, "SwiftLint")
        XCTAssertEqual(kind, .plugin)
    }

    func testParsesDependencyPlatformConditions() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "App": {
                  "product": "app",
                  "dependencies": [
                    {
                      "target": {
                        "name": "Framework",
                        "condition": {
                          "platformFilters": [
                            { "ios": {} },
                            { "macos": {} }
                          ]
                        }
                      }
                    },
                    {
                      "project": {
                        "target": "WatchFramework",
                        "path": "/tmp/Frameworks",
                        "condition": {
                          "platformFilters": [
                            { "watchos": {} }
                          ]
                        }
                      }
                    }
                  ]
                }
              }
            }
          }
        }
        """

        let dependencies = try TuistGraphParser().parse(data: Data(json.utf8)).projects[0].targets[0].dependencies

        guard case let .target(name, condition) = dependencies[0] else {
            return XCTFail("expected target dependency")
        }
        XCTAssertEqual(name, "Framework")
        XCTAssertEqual(condition?.platformFilters, ["ios", "macos"])

        guard case let .project(target, path, condition) = dependencies[1] else {
            return XCTFail("expected project dependency")
        }
        XCTAssertEqual(target, "WatchFramework")
        XCTAssertEqual(path, "/tmp/Frameworks")
        XCTAssertEqual(condition?.platformFilters, ["watchos"])
    }

    func testParsesSettingsBackedInfoPlistEntries() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "WatchApp": {
                  "product": "app",
                  "settings": {
                    "base": {
                      "CURRENT_PROJECT_VERSION": { "string": { "_0": "1.0" } },
                      "MARKETING_VERSION": { "string": { "_0": "2.0" } },
                      "INFOPLIST_KEY_WKCompanionAppBundleIdentifier": { "string": { "_0": "dev.tuist.App" } },
                      "INFOPLIST_KEY_WKRunsIndependentlyOfCompanionApp": { "string": { "_0": "NO" } },
                      "INFOPLIST_KEY_UISupportedInterfaceOrientations": {
                        "array": {
                          "_0": [
                            "UIInterfaceOrientationPortrait",
                            "UIInterfaceOrientationPortraitUpsideDown"
                          ]
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
        """

        let graph = try TuistGraphParser().parse(data: Data(json.utf8))
        let entries = try XCTUnwrap(graph.projects.first?.targets.first?.infoPlistEntries)

        XCTAssertEqual(entries["CFBundleVersion"], .string("1.0"))
        XCTAssertEqual(entries["CFBundleShortVersionString"], .string("2.0"))
        XCTAssertEqual(entries["WKCompanionAppBundleIdentifier"], .string("dev.tuist.App"))
        XCTAssertEqual(entries["WKRunsIndependentlyOfCompanionApp"], .bool(false))
        XCTAssertEqual(
            entries["UISupportedInterfaceOrientations"],
            .array([
                .string("UIInterfaceOrientationPortrait"),
                .string("UIInterfaceOrientationPortraitUpsideDown"),
            ])
        )
    }

    func testParsesMacroProducts() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "Macros": {
                  "product": "macro",
                  "sources": [
                    {
                      "path": "/tmp/App/Sources/Macros/Macros.swift"
                    }
                  ]
                }
              }
            }
          }
        }
        """

        let graph = try TuistGraphParser().parse(data: Data(json.utf8))
        let target = try XCTUnwrap(graph.projects.first?.targets.first)

        XCTAssertEqual(target.product, .macro)
        XCTAssertEqual(target.sources, ["/tmp/App/Sources/Macros/Macros.swift"])
    }

    func testTreatsAppClipProductAsUnsupported() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "AppClip": {
                  "product": "appClip",
                  "bundleId": "dev.tuist.App.Clip",
                  "productName": "AppClip",
                  "sources": [
                    {
                      "path": "/tmp/App/AppClip/Sources/AppClip.swift"
                    }
                  ]
                }
              }
            }
          }
        }
        """

        let target = try TuistGraphParser().parse(data: Data(json.utf8)).projects[0].targets[0]

        XCTAssertEqual(target.product, .unsupported)
        XCTAssertEqual(target.bundleId, "dev.tuist.App.Clip")
    }

    func testRecordsCoreDataModelsForUnsupportedFeatureDiagnostics() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "App": {
                  "product": "app",
                  "coreDataModels": [
                    {
                      "currentVersion": "2",
                      "path": "/tmp/App/CoreData/Users.xcdatamodeld",
                      "versions": [
                        "/tmp/App/CoreData/Users.xcdatamodeld/1.xcdatamodel",
                        "/tmp/App/CoreData/Users.xcdatamodeld/2.xcdatamodel"
                      ]
                    }
                  ]
                }
              }
            }
          }
        }
        """

        let target = try TuistGraphParser().parse(data: Data(json.utf8)).projects[0].targets[0]

        XCTAssertEqual(target.coreDataModelPaths, ["/tmp/App/CoreData/Users.xcdatamodeld"])
    }

    func testTreatsSpecializedExtensionProductsAsUnsupported() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "AppIntentExtension": {
                  "product": "extension_kit_extension",
                  "bundleId": "dev.tuist.App.AppIntentExtension",
                  "productName": "AppIntentExtension",
                  "infoPlist": {
                    "extendingDefault": {
                      "with": {
                        "EXAppExtensionAttributes": {
                          "dictionary": {
                            "_0": {
                              "EXExtensionPointIdentifier": {
                                "string": { "_0": "com.apple.appintents-extension" }
                              }
                            }
                          }
                        }
                      }
                    }
                  },
                  "sources": [],
                  "resources": { "resources": [] },
                  "dependencies": []
                },
                "MessageExtension": {
                  "product": "messages_extension",
                  "bundleId": "dev.tuist.App.MessageExtension",
                  "productName": "MessageExtension",
                  "infoPlist": { "extendingDefault": { "with": {} } },
                  "sources": [],
                  "resources": { "resources": [] },
                  "dependencies": []
                },
                "StickersPackExtension": {
                  "product": "sticker_pack_extension",
                  "bundleId": "dev.tuist.App.StickersPackExtension",
                  "productName": "StickersPackExtension",
                  "infoPlist": { "extendingDefault": { "with": {} } },
                  "sources": [],
                  "resources": { "resources": [] },
                  "dependencies": []
                }
              }
            }
          }
        }
        """

        let targets = try TuistGraphParser().parse(data: Data(json.utf8)).projects[0].targets

        XCTAssertEqual(targets.map(\.product), [.unsupported, .unsupported, .unsupported])
        XCTAssertEqual(
            targets[0].infoPlistEntries["EXAppExtensionAttributes"],
            .dictionary(["EXExtensionPointIdentifier": .string("com.apple.appintents-extension")])
        )
    }

    func testTreatsTVTopShelfExtensionProductAsUnsupported() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "TopShelfExtension": {
                  "product": "tv_top_shelf_extension",
                  "destinations": ["appleTv"],
                  "bundleId": "dev.tuist.App.TopShelfExtension",
                  "productName": "TopShelfExtension",
                  "infoPlist": { "extendingDefault": { "with": {} } },
                  "sources": [{ "path": "/tmp/App/TopShelfExtension/ContentProvider.swift" }],
                  "resources": { "resources": [] },
                  "dependencies": []
                }
              }
            }
          }
        }
        """

        let target = try TuistGraphParser().parse(data: Data(json.utf8)).projects[0].targets[0]

        XCTAssertEqual(target.product, .unsupported)
        XCTAssertEqual(target.destinations, ["appleTv"])
    }

    func testParsesBuildableFolderResolvedFilesAsSourcesAndResources() throws {
        let json = """
        {
          "name": "Fixture",
          "projects": {
            "/tmp/App": {
              "name": "App",
              "targets": {
                "Framework": {
                  "product": "framework",
                  "bundleId": "dev.tuist.Framework",
                  "productName": "Framework",
                  "infoPlist": { "extendingDefault": { "with": {} } },
                  "sources": [],
                  "resources": { "resources": [] },
                  "buildableFolders": [
                    {
                      "path": "/tmp/App/Modules/Framework",
                      "resolvedFiles": [
                        { "path": "/tmp/App/Modules/Framework/Sources/Provider.swift" },
                        { "path": "/tmp/App/Modules/Framework/Resources/Assets.xcassets" },
                        { "path": "/tmp/App/Modules/Framework/Sources/Internal.h" }
                      ]
                    }
                  ],
                  "dependencies": []
                }
              }
            }
          }
        }
        """

        let target = try TuistGraphParser().parse(data: Data(json.utf8)).projects[0].targets[0]

        XCTAssertEqual(target.sources, ["/tmp/App/Modules/Framework/Sources/Provider.swift"])
        XCTAssertEqual(target.resources.map(\.path), ["/tmp/App/Modules/Framework/Resources/Assets.xcassets"])
    }
}
