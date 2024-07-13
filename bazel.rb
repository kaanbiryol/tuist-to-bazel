
require 'pathname'
require_relative 'dependency_resolver'
require_relative 'utils'
require_relative 'gen_module'
require_relative 'gen_root_build'
require_relative 'gen_target_build'
require_relative 'bazel_target'
require_relative 'gen_swift_deps_index'
require_relative 'generator'
require_relative 'gen_local_framework_build'

# Skip tests and Swifltint target for now
def should_skip(target)
    target_name = target["name"]
    target_type = target["product"]
    
    if target_type == "unit_tests"
        return true
    end
    if target_name.include?("Test") || target_name.include?("SwiftLint")
        return true
    end
    return false
end

# {"identity"=>"needle", "name"=>"NeedleFoundationTest", "type"=>"library", "label"=>"@swiftpkg_needle//:NeedleFoundationTest"}
# {"identity"=>"nuke", "name"=>"Nuke", "type"=>"library", "label"=>"@swiftpkg_nuke//:Nuke"}
# {"identity"=>"nuke", "name"=>"NukeExtensions", "type"=>"library", "label"=>"@swiftpkg_nuke//:NukeExtensions"}
# {"identity"=>"nuke", "name"=>"NukeUI", "type"=>"library", "label"=>"@swiftpkg_nuke//:NukeUI"}
# {"identity"=>"nuke", "name"=>"NukeVideo", "type"=>"library", "label"=>"@swiftpkg_nuke//:NukeVideo"}

def main(tuist_graph_path, package_swift_path)
    if not file_exists(MODULE_FILE)
        generate_module
    end
    if not file_exists(SWIFT_DEPS_INDEX_FILE)
        generate_swift_deps_index(package_swift_path)
    end
    generate_bazel_project(tuist_graph_path, "#{Dir.pwd}/#{SWIFT_DEPS_INDEX_FILE}")
end

tuist_graph_path = ARGV[0]
package_swift_path = ARGV[1]
main(tuist_graph_path, package_swift_path)
