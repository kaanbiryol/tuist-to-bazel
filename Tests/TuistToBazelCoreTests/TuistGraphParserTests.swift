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
        XCTAssertEqual(graph.projects[0].targets[0].resources.count, 2)
        XCTAssertEqual(graph.projects[0].targets[0].dependencies.count, 1)
    }
}
