#!/usr/bin/env bash
set -euo pipefail

approved_url="https://github.com/swiftlang/swift-markdown.git"
approved_identity="swift-markdown"
approved_transitive_identity="swift-cmark"

if ! command -v swift >/dev/null 2>&1; then
  echo "error: swift is required to check Quoin's dependency policy." >&2
  exit 1
fi

package_file="$(mktemp)"
violations_file="$(mktemp)"
trap 'rm -f "$package_file" "$violations_file"' EXIT

swift package dump-package > "$package_file"

dependency_count="$(
  /usr/bin/python3 - "$approved_url" "$package_file" 2> "$violations_file" <<'PY'
import json
import sys

approved_url = sys.argv[1]
package_path = sys.argv[2]
with open(package_path, encoding="utf-8") as handle:
    package = json.load(handle)
deps = package.get("dependencies", [])
violations = []

def remote_url(dep):
    source = dep.get("sourceControl", [{}])[0]
    remote = source.get("location", {}).get("remote", [None])[0]
    if isinstance(remote, dict):
        return remote.get("urlString")
    return remote

for dep in deps:
    location = remote_url(dep)
    if location != approved_url:
        violations.append(location or "<unknown>")

print(len(deps))
if violations:
    print("\n".join(violations), file=sys.stderr)
PY
)"

if [[ "$dependency_count" != "1" ]]; then
  echo "error: Quoin allows exactly one direct package dependency: $approved_url" >&2
  echo "Found $dependency_count direct dependencies." >&2
  echo "New code dependencies require written TRD justification before this guard is relaxed." >&2
  exit 1
fi

if [[ -s "$violations_file" ]]; then
  echo "error: Package.swift contains unapproved package dependencies:" >&2
  sed 's/^/  - /' "$violations_file" >&2
  echo "New code dependencies require written TRD justification before this guard is relaxed." >&2
  exit 1
fi

if [[ -f Package.resolved ]]; then
  /usr/bin/python3 - "$approved_identity" "$approved_transitive_identity" Package.resolved <<'PY'
import json
import sys

allowed = set(sys.argv[1:3])
resolved_path = sys.argv[3]
with open(resolved_path, encoding="utf-8") as handle:
    resolved = json.load(handle)
pins = resolved.get("pins", [])
unexpected = sorted(
    pin.get("identity", "<unknown>")
    for pin in pins
    if pin.get("identity") not in allowed
)

if unexpected:
    print("error: Package.resolved contains unapproved pins:", file=sys.stderr)
    for identity in unexpected:
        print(f"  - {identity}", file=sys.stderr)
    print("Only swift-markdown and its existing swift-cmark transitive pin are allowed without TRD justification.", file=sys.stderr)
    sys.exit(1)
PY
fi

echo "Dependency policy OK: direct dependency is $approved_url; existing swift-cmark transitive pin is allowed."
