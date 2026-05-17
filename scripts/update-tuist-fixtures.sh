#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tuist_repo="https://github.com/tuist/tuist"
tuist_commit="${TUIST_COMMIT:-2be1eb0076143ebc60e86fff7b5c334c0808baa3}"
tmp_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

archive="$tmp_dir/tuist.tar.gz"
curl -fsSL "$tuist_repo/archive/$tuist_commit.tar.gz" -o "$archive"
tar -xzf "$archive" -C "$tmp_dir"
upstream_root="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
upstream_examples="$upstream_root/examples/xcode"

write_metadata() {
  local destination="$1"
  local source_path="$2"
  local generated="$3"

  if [[ "$generated" == "true" ]]; then
    cat > "$destination/.upstream.json" <<JSON
{
  "repository": "$tuist_repo",
  "commit": "$tuist_commit",
  "sourcePath": "$source_path",
  "generatedBazelOutput": true,
  "refreshScript": "scripts/update-tuist-fixtures.sh",
  "notes": [
    "Generated Bazel files are committed next to the Tuist fixture files.",
    "The SF-Pro-Display font files are filename-only placeholders because tuist-to-bazel derives accessors from resource filenames."
  ]
}
JSON
    return 0
  fi

  cat > "$destination/.upstream.json" <<JSON
{
  "repository": "$tuist_repo",
  "commit": "$tuist_commit",
  "sourcePath": "$source_path",
  "generatedBazelOutput": $generated,
  "refreshScript": "scripts/update-tuist-fixtures.sh"
}
JSON
}

replace_font_payloads() {
  local fixture_dir="$1"
  local font_dir="$fixture_dir/App/Resources/Fonts"

  [[ -d "$font_dir" ]] || return 0

  for font_file in \
    "$font_dir/SF-Pro-Display-Bold.otf" \
    "$font_dir/SF-Pro-Display-BoldItalic.otf" \
    "$font_dir/SF-Pro-Display-Heavy.otf"; do
    [[ -e "$font_file" ]] || continue
    printf 'placeholder: filename-only fixture for tuist-to-bazel tests\n' > "$font_file"
  done
}

sync_raw_fixture() {
  local name="$1"
  local destination="$2"
  local source="$upstream_examples/$name"

  [[ -d "$source" ]] || {
    echo "error: upstream fixture not found: $source" >&2
    return 1
  }

  mkdir -p "$destination"
  rsync -a --delete "$source/" "$destination/"
  replace_font_payloads "$destination"
  write_metadata "$destination" "examples/xcode/$name" "false"
}

sync_showcase_fixture() {
  local name="generated_ios_app_with_framework_and_resources"
  local destination="$repo_root/Examples/$name"
  local source="$upstream_examples/$name"

  [[ -d "$source" ]] || {
    echo "error: upstream fixture not found: $source" >&2
    return 1
  }

  mkdir -p "$destination"
  rsync -a --delete \
    --exclude '.bazel/' \
    --exclude 'BUILD.bazel' \
    --exclude 'MODULE.bazel' \
    --exclude 'MODULE.bazel.lock' \
    --exclude 'README.md' \
    --exclude 'bazel-*' \
    "$source/" "$destination/"
  replace_font_payloads "$destination"
  write_metadata "$destination" "examples/xcode/$name" "true"

  if command -v tuist >/dev/null 2>&1; then
    graph_dir="$tmp_dir/graph"
    (cd "$destination" && tuist graph -f json --no-open --output-path "$graph_dir")
    swift run --package-path "$repo_root" tuist-to-bazel convert \
      --graph "$graph_dir/graph.json" \
      --root "$destination" \
      --output "$destination" \
      --force
  else
    echo "warning: tuist not found; source fixture refreshed but generated Bazel files were left as-is." >&2
  fi
}

sync_raw_fixture \
  "generated_app_with_framework_and_tests" \
  "$repo_root/Tests/Fixtures/TuistProjects/generated_app_with_framework_and_tests"

sync_showcase_fixture

echo "Updated Tuist fixtures from $tuist_repo@$tuist_commit"
