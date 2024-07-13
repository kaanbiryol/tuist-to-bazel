# Generates a BUILD.bazel file for a given target
def generate_local_framework_build(local_frameworks)
    local_frameworks_string = if local_frameworks.nil?
        ""
      else
        local_frameworks.flat_map { |framework|
          next if framework.nil? || framework[0].nil? || framework[0].empty?
          framework
        }.compact.map { |framework|
          gen_local_framework_filegroup(framework)
        }.join("\n")
      end

    if local_frameworks_string.empty?
        return
    end

    # puts local_frameworks_string

    build_content = <<~BUILD
        load("@build_bazel_rules_apple//apple:apple.bzl", "apple_static_xcframework_import")

        #{local_frameworks_string}
    BUILD
    
   
    # multiple folders?
    File.open("#{Dir.pwd}/vendor/BUILD.bazel", 'w') do |file|
      file.write(build_content)
    end
end

def gen_local_framework_filegroup(local_framework)
    puts local_framework[0]
    build_content = <<~BUILD
        apple_static_xcframework_import(
            name = "#{local_framework[0].split(":")[1]}",
            xcframework_imports = glob(["#{local_framework[1]}/**"]),
            visibility = ["//visibility:public"],
        )
    BUILD
end