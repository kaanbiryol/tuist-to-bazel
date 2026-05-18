#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/Fixtures/manifest.json"
python_bin="${PYTHON:-python3}"
tmp_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

read_manifest_value() {
  local expression="$1"
  "$python_bin" - "$manifest" "$expression" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    value = json.load(file)

for component in sys.argv[2].split("."):
    value = value[component]

print(value)
PY
}

read_sync_source_paths() {
  "$python_bin" - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    manifest = json.load(file)

upstream_path = manifest["corpus"]["upstreamPath"]
fixtures_by_name = {fixture["name"]: fixture for fixture in manifest["fixtures"]}
paths = []

for fixture in manifest["fixtures"]:
    paths.append(fixture["upstreamTuistPath"])

for showcase in manifest.get("showcases", []):
    source_name = showcase["sourceFixture"]
    source_fixture = fixtures_by_name.get(source_name)
    if source_fixture is not None:
        paths.append(source_fixture["upstreamTuistPath"])
    else:
        paths.append(f"{upstream_path}/{source_name}")

seen = set()
for path in paths:
    if path in seen:
        continue
    seen.add(path)
    print(path)
PY
}

read_corpus_rows() {
  "$python_bin" - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    manifest = json.load(file)

corpus_path = manifest["corpus"]["localPath"]
prefix = f"{corpus_path}/"

for fixture in manifest["fixtures"]:
    local_path = fixture["localPath"]
    if not local_path.startswith(prefix):
        continue
    print("\t".join([fixture["name"], fixture["upstreamTuistPath"], local_path]))
PY
}

read_showcase_rows() {
  "$python_bin" - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    manifest = json.load(file)

for showcase in manifest.get("showcases", []):
    print("\t".join([showcase["name"], showcase["sourceFixture"], showcase["localPath"]]))
PY
}

tuist_repo="$(read_manifest_value "upstream.repository")"
tuist_commit="${TUIST_COMMIT:-$(read_manifest_value "upstream.commit")}"
upstream_path="$(read_manifest_value "corpus.upstreamPath")"
corpus_path="$(read_manifest_value "corpus.localPath")"
corpus_destination="$repo_root/$corpus_path"
checkout_dir="$tmp_dir/tuist"

clone_upstream_sparse() {
  local sparse_paths=()
  while IFS= read -r source_path; do
    [[ -n "$source_path" ]] || continue
    sparse_paths+=("$source_path")
  done < <(read_sync_source_paths)

  [[ ${#sparse_paths[@]} -gt 0 ]] || {
    echo "error: no fixture paths selected in $manifest" >&2
    return 1
  }

  git clone --filter=blob:none --no-checkout "$tuist_repo" "$checkout_dir"
  git -C "$checkout_dir" sparse-checkout init --cone
  git -C "$checkout_dir" sparse-checkout set "${sparse_paths[@]}"
  git -C "$checkout_dir" fetch --depth 1 origin "$tuist_commit"
  git -C "$checkout_dir" checkout --detach FETCH_HEAD
}

write_metadata() {
  local destination="$1"
  local source_path="$2"
  local generated="$3"
  local notes_json="${4:-[]}"

  cat > "$destination/.upstream.json" <<JSON
{
  "repository": "$tuist_repo",
  "commit": "$tuist_commit",
  "sourcePath": "$source_path",
  "generatedBazelOutput": $generated,
  "refreshScript": "scripts/update-tuist-fixtures.sh",
  "notes": $notes_json
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

patch_visionos_fixture_for_current_sdk() {
  local fixture_dir="$1"
  local source_file="$fixture_dir/Sources/AppDelegate.swift"

  [[ -f "$source_file" ]] || return 0

  "$python_bin" - "$source_file" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text()
content = content.replace(
    "window = UIWindow(frame: UIScreen.main.bounds)",
    "window = UIWindow(frame: .zero)",
)
path.write_text(content)
PY
}
sync_corpus() {
  local rows_file="$tmp_dir/corpus-fixtures.tsv"
  local names_file="$tmp_dir/corpus-fixture-names.txt"

  read_corpus_rows > "$rows_file"
  cut -f1 "$rows_file" > "$names_file"

  [[ -s "$rows_file" ]] || {
    echo "error: no corpus fixtures selected in $manifest" >&2
    return 1
  }

  mkdir -p "$corpus_destination"

  while IFS=$'\t' read -r name source_path local_path; do
    local source="$checkout_dir/$source_path"
    local destination="$repo_root/$local_path"

    [[ -d "$source" ]] || {
      echo "error: selected upstream fixture not found: $source_path" >&2
      return 1
    }

    mkdir -p "$destination"
    rsync -a --delete \
      --exclude '.build/' \
      --exclude 'Derived/' \
      --exclude 'bazel-*' \
      "$source/" "$destination/"

    replace_font_payloads "$destination"
    local notes='[]'
    if [[ "$name" == "generated_visionos_app" ]]; then
      patch_visionos_fixture_for_current_sdk "$destination"
      notes='[
    "Sources/AppDelegate.swift is patched locally to avoid Xcode 26 UIScreen availability failure for visionOS."
  ]'
    fi
    write_metadata "$destination" "$source_path" "false" "$notes"
  done < "$rows_file"

  find "$corpus_destination" -mindepth 1 -maxdepth 1 -type d | while IFS= read -r fixture_dir; do
    local name
    name="$(basename "$fixture_dir")"
    if ! grep -Fxq "$name" "$names_file"; then
      rm -rf "$fixture_dir"
    fi
  done
}

sync_showcase_fixtures() {
  local rows_file="$tmp_dir/showcases.tsv"
  local notes='[
    "Generated Bazel files are committed next to the Tuist fixture files.",
    "The SF-Pro-Display font files are filename-only placeholders because tuist-to-bazel derives accessors from resource filenames."
  ]'

  read_showcase_rows > "$rows_file"
  [[ -s "$rows_file" ]] || return 0

  while IFS=$'\t' read -r name source_fixture local_path; do
    local source="$corpus_destination/$source_fixture"
    local destination="$repo_root/$local_path"
    local source_path="$upstream_path/$source_fixture"

    [[ -d "$source" ]] || {
      echo "error: showcase source not found in corpus: $source" >&2
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
    write_metadata "$destination" "$source_path" "true" "$notes"

    if command -v tuist >/dev/null 2>&1; then
      local graph_dir="$tmp_dir/graph-$name"
      mkdir -p "$graph_dir"
      (cd "$destination" && tuist graph -f json --no-open --output-path "$graph_dir")
      swift run --package-path "$repo_root" tuist-to-bazel convert \
        --graph "$graph_dir/graph.json" \
        --root "$destination" \
        --output "$destination" \
        --force
    else
      echo "warning: tuist not found; source fixture refreshed but generated Bazel files were left as-is: $name" >&2
    fi
  done < "$rows_file"
}

clone_upstream_sparse
sync_corpus
sync_showcase_fixtures

fixture_count="$(find "$corpus_destination" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
echo "Updated $fixture_count selected Tuist xcode fixtures from $tuist_repo@$tuist_commit"
