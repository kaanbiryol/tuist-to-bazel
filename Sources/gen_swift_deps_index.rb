SWIFT_DEPS_INDEX_FILE = "swift_deps_index.json"

def generate_swift_deps_index(package_swift_path)
  filename = File.basename(package_swift_path)
    destination_path = File.join(Dir.pwd, filename)
  unless File.exist?(destination_path)
    FileUtils.cp(package_swift_path, destination_path)
  end

  `bazel run //:swift_update_pkgs`

  FileUtils.rm(destination_path) if File.exist?(destination_path)
end