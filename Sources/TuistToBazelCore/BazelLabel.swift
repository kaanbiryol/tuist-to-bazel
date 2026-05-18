import Foundation

struct BazelLabel: Hashable, Comparable {
    let package: String
    let name: String

    static func < (lhs: BazelLabel, rhs: BazelLabel) -> Bool {
        lhs.description < rhs.description
    }

    var description: String {
        if package.hasPrefix("@") {
            return "\(package)//:\(name)"
        }
        return package.isEmpty ? "//:\(name)" : "//\(package):\(name)"
    }

    func localDescription(in packagePath: String) -> String {
        package == packagePath ? ":\(name)" : description
    }
}

func sanitizedModuleName(_ value: String) -> String {
    var result = ""
    for scalar in value.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
            result.unicodeScalars.append(scalar)
        } else {
            result.append("_")
        }
    }
    if result.first?.isNumber == true {
        result = "_\(result)"
    }
    return result.isEmpty ? "Module" : result
}
