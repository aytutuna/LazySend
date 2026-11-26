#!/bin/bash
# Runs require_green_main.sh against a stand-in gh that answers from FAKE_STATE and FAKE_RUN.
set -u

here="$(cd "$(dirname "$0")" && pwd)"
bin="$(mktemp -d)"
trap 'rm -rf "$bin"' EXIT
cat > "$bin/gh" <<'GH'
#!/bin/bash
case "$1" in
  api) echo "$FAKE_STATE" ;;
  run) echo "$FAKE_RUN" ;;
esac
GH
chmod +x "$bin/gh"

failed=0
expect() {
  local want="$1" state="$2" run="$3" label="$4"
  FAKE_STATE="$state" FAKE_RUN="$run" PATH="$bin:$PATH" bash "$here/require_green_main.sh" 0123456789abcdef x/y >/dev/null 2>&1
  local got=$?
  if { [ "$want" = pass ] && [ "$got" -ne 0 ]; } || { [ "$want" = stop ] && [ "$got" -eq 0 ]; }; then
    echo "FAIL: $label (exit $got)"
    failed=1
  fi
}

expect pass identical "completed success" "main's tip with a green run"
expect pass behind "completed success" "an older commit of main with a green run"
expect stop ahead "completed success" "a commit ahead of main"
expect stop diverged "completed success" "a commit on another branch"
expect stop identical "completed failure" "a red run"
expect stop identical "in_progress " "a run still going"
expect stop identical "null null" "no run"
expect stop identical "" "no output"
[ "$failed" -eq 0 ] && echo "require_green_main.sh stops where it should"
exit "$failed"
