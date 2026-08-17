#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$repo_root/Fixtures/manifest.json"
python_bin="${PYTHON:-python3}"
tool_path="${TUIST_TO_BAZEL_BIN:-$repo_root/.build/release/tuist-to-bazel}"
skip_tests=false
all_supported=false
fixtures=()
work_dirs=()

usage() {
  cat <<'USAGE'
Usage: scripts/verify-tuist-fixtures.sh [--skip-tests] <fixture>...
       scripts/verify-tuist-fixtures.sh [--skip-tests] --all-supported

Runs each supported fixture's verificationCommands against an isolated copy.
Set TUIST_TO_BAZEL_BIN to use a converter outside .build/release.
USAGE
}

cleanup() {
  local work_dir
  for work_dir in "${work_dirs[@]-}"; do
    [[ -n "$work_dir" ]] || continue
    rm -rf -- "$work_dir"
  done
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-supported)
      all_supported=true
      ;;
    --skip-tests)
      skip_tests=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      fixtures+=("$1")
      ;;
  esac
  shift
done

if $all_supported; then
  [[ ${#fixtures[@]} -eq 0 ]] || {
    echo "error: --all-supported cannot be combined with fixture names" >&2
    exit 2
  }
  while IFS= read -r fixture; do
    fixtures+=("$fixture")
  done < <(
    "$python_bin" - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    manifest = json.load(file)

for fixture in manifest["fixtures"]:
    if fixture["expectedStatus"] == "supported":
        print(fixture["name"])
PY
  )
fi

[[ ${#fixtures[@]} -gt 0 ]] || {
  usage >&2
  exit 2
}

for dependency in "$python_bin" tuist bazelisk; do
  command -v "$dependency" >/dev/null 2>&1 || {
    echo "error: required command not found: $dependency" >&2
    exit 1
  }
done

[[ -x "$tool_path" ]] || {
  echo "error: converter executable not found at $tool_path" >&2
  echo "Build it first with: swift build -c release" >&2
  exit 1
}

for fixture_name in "${fixtures[@]}"; do
  fixture_path=""
  fixture_status=""
  commands=()

  while IFS=$'\t' read -r kind value; do
    case "$kind" in
      path) fixture_path="$value" ;;
      status) fixture_status="$value" ;;
      command) commands+=("$value") ;;
    esac
  done < <(
    "$python_bin" - "$manifest" "$fixture_name" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as file:
    manifest = json.load(file)

fixture = next(
    (item for item in manifest["fixtures"] if item["name"] == sys.argv[2]),
    None,
)
if fixture is None:
    raise SystemExit(f"unknown fixture: {sys.argv[2]}")

print(f"path\t{fixture['localPath']}")
print(f"status\t{fixture['expectedStatus']}")
for command in fixture.get("verificationCommands", []):
    print(f"command\t{command}")
PY
  )

  [[ "$fixture_status" == "supported" ]] || {
    echo "error: fixture is not marked supported: $fixture_name" >&2
    exit 1
  }
  [[ ${#commands[@]} -gt 0 ]] || {
    echo "error: fixture has no verification commands: $fixture_name" >&2
    exit 1
  }

  source_dir="$repo_root/$fixture_path"
  [[ -d "$source_dir" ]] || {
    echo "error: fixture directory not found: $source_dir" >&2
    exit 1
  }

  work_dir="$(mktemp -d "${TMPDIR:-/tmp}/tuist-to-bazel-${fixture_name}.XXXXXX")"
  work_dirs+=("$work_dir")
  fixture_copy="$work_dir/fixture"
  mkdir -p "$fixture_copy"
  cp -R "$source_dir/." "$fixture_copy"

  echo "Verifying $fixture_name"
  for verification_command in "${commands[@]}"; do
    case "$verification_command" in
      "tuist install"|"tuist graph "*|"tuist-to-bazel convert "*|"bazelisk query "*|"bazelisk build "*|"bazelisk test "*)
        ;;
      *)
        echo "error: unsupported verification command for $fixture_name: $verification_command" >&2
        exit 1
        ;;
    esac

    if $skip_tests && [[ "$verification_command" == "bazelisk test "* ]]; then
      echo "+ skipped: $verification_command"
      continue
    fi

    verification_command="${verification_command//<tmp>/$work_dir}"
    verification_command="${verification_command//<fixture-copy>/$fixture_copy}"
    verification_command="${verification_command//<fixture>/$fixture_copy}"
    if [[ "$verification_command" == "tuist-to-bazel "* ]]; then
      verification_command="\"$tool_path\" ${verification_command#tuist-to-bazel }"
    fi

    echo "+ $verification_command"
    (cd "$fixture_copy" && /bin/bash -c "$verification_command")
  done
done

echo "Verified ${#fixtures[@]} fixture(s)."
