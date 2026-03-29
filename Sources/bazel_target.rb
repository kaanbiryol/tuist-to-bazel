class BazelTarget
    attr_accessor :absolute_path, :relative_path, :target_name, :dependencies, :type, :bundle_id, :infoplist

    def initialize(absolute_path, relative_path, target_name, dependencies, type, bundle_id: nil, infoplist: nil)
        @absolute_path = absolute_path
        @relative_path = relative_path
        @target_name = target_name
        @dependencies = dependencies
        @type = type
        @bundle_id = bundle_id
        @infoplist = infoplist
    end

    def label
        if type == "app" || type == "app_extension"
            return "//#{relative_path}:#{target_name}Lib"
        end
        return "//#{relative_path}:#{target_name}"
    end
end

# Generates BazelTarget from the new XcodeGraph format
def bazel_target(target_name, target)
    type = target["product"]
    abs_path = source_directory(target)
    rel_path = abs_path ? relative_path(abs_path) : target_name
    dependencies = target["dependencies"] || []
    bundle_id = target["bundleId"]
    infoplist_data = target["infoPlist"]
    infoplist = nil
    if infoplist_data && infoplist_data["file"]
        infoplist_abs = infoplist_data["file"]["path"]
        if infoplist_abs
            infoplist_rel = relative_path(infoplist_abs)
            infoplist_dir = File.dirname(infoplist_rel)
            infoplist_name = File.basename(infoplist_rel)
            if infoplist_dir == rel_path
                # Same package - use filename directly
                infoplist = infoplist_name
            elsif infoplist_dir == "."
                # Root package
                infoplist = "//:#{infoplist_name}"
            else
                # Different package
                infoplist = "//#{infoplist_dir}:#{infoplist_name}"
            end
        end
    end
    return BazelTarget.new(abs_path, rel_path, target_name, dependencies, type, bundle_id: bundle_id, infoplist: infoplist)
end