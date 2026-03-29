
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

def main(tuist_graph_path, package_swift_path = nil)
    unless file_exists(MODULE_FILE)
        generate_module
    end
    swift_deps_index = nil
    if package_swift_path
        unless file_exists(SWIFT_DEPS_INDEX_FILE)
            generate_swift_deps_index(package_swift_path)
        end
        swift_deps_index = "#{Dir.pwd}/#{SWIFT_DEPS_INDEX_FILE}"
    end
    generate_bazel_project(tuist_graph_path, swift_deps_index)
end

tuist_graph_path = ARGV[0]
package_swift_path = ARGV[1]
main(tuist_graph_path, package_swift_path)
