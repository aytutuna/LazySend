#!/bin/bash
# Stops an upload unless the commit is on main and its ci.yml run passed.
#   require_green_main.sh <sha> [owner/repo]
# Needs the gh CLI and, in a workflow, GH_TOKEN with actions: read.
set -euo pipefail

sha="${1:?usage: require_green_main.sh <sha> [owner/repo]}"
repo="${2:-${GITHUB_REPOSITORY:-aytutuna/LazySend}}"

# "behind" means the commit is in main's history, "identical" that it is main's tip.
state=$(gh api "repos/$repo/compare/main...$sha" --jq .status)
if [ "$state" != "identical" ] && [ "$state" != "behind" ]; then
  echo "Refusing to upload: ${sha:0:7} is not on main ($state)." >&2
  exit 1
fi

# The newest run of ci.yml for this commit decides; a rerun replaces the failure it fixes.
run=$(gh run list -R "$repo" --workflow ci.yml --commit "$sha" --limit 1 --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"')
if [ -z "$run" ] || [ "$run" = "null null" ]; then
  echo "Refusing to upload: ci.yml has not run for ${sha:0:7}." >&2
  exit 1
fi
if [ "$run" != "completed success" ]; then
  echo "Refusing to upload: the ci.yml run for ${sha:0:7} is not green ($run)." >&2
  exit 1
fi
echo "${sha:0:7} is on main and its ci.yml run is green."
