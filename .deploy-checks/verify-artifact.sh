#!/usr/bin/env bash
# Host-side artifact gate for ethos-aloft-site (the PUBLIC build-output mirror).
#
# Runs as the Render service's build command. publishPath is "." and buildCommand
# has historically been empty, so nothing host-side has ever stood between a bad
# dist/ copy and the live site. This is that check.
#
# WHY HOST-SIDE. The guards in the SOURCE repo's package.json are per-commit
# artifacts: they cannot protect a worktree parked at an older commit, and there
# are 32 worktrees. A build command cannot be missing from a checkout, because
# there is no checkout - it is service config pointed at versioned logic.
#
# MODE. Defaults to ENFORCE. Report-only requires an explicit
# ARTIFACT_GATE_MODE=report. A missing or misspelled variable therefore fails
# CLOSED (enforcing), never open - a default of "report" would be a silent-zero
# generator, which is the failure class this gate exists to catch.
#
# ⛔ ROLLBACK LEVER, one edit, restores the previous behaviour exactly:
#    clear the service's Build Command back to empty in the Render dashboard.
#    Nothing else needs undoing. The check writes nothing and moves nothing.
#    If this gate ever refuses a deploy you believe is good, clear the build
#    command, publish, and then work out which assertion was wrong. Do not
#    "fix" it by weakening an assertion under time pressure.
set -uo pipefail

MODE="${ARTIFACT_GATE_MODE:-enforce}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MANIFEST="$HERE/routes.txt"
fail=0
note () { printf '  %s\n' "$*"; }
bad  () { printf 'FAIL  %s\n' "$*"; fail=1; }

echo "artifact gate: mode=$MODE root=$ROOT"

# --- fail closed on the checker's own preconditions ---------------------------
[ -d "$ROOT" ]       || { echo "FATAL: root not a directory"; exit 1; }
[ -r "$MANIFEST" ]   || { echo "FATAL: route manifest missing at $MANIFEST"; exit 1; }
# Portable read loop, NOT mapfile: mapfile is bash 4+ and absent on bash 3.2.
# The first version used it and died FATAL on a good tree - correct direction,
# but a gate that depends on the build image's bash version is a gate that can
# start refusing everything after an unrelated image change.
ROUTES=()
while IFS= read -r line; do
  case "$line" in ""|" "*) [ -z "${line// /}" ] && continue;; esac
  ROUTES+=("$line")
done < "$MANIFEST" || { echo "FATAL: cannot read manifest"; exit 1; }
[ "${#ROUTES[@]}" -gt 0 ] || { echo "FATAL: manifest is empty"; exit 1; }
dupes=$(printf '%s\n' "${ROUTES[@]}" | sort | uniq -d)
[ -z "$dupes" ] || { echo "FATAL: duplicate routes in manifest: $dupes"; exit 1; }
note "manifest routes: ${#ROUTES[@]}"

# --- 1. the apex document exists and is prerendered ---------------------------
APEX="$ROOT/index.html"
if [ ! -s "$APEX" ]; then
  bad "index.html missing or empty at the publish root"
else
  # An EMPTY root div is the signature of vite build without the prerender step.
  if grep -q '<div id="root"></div>' "$APEX"; then
    bad "index.html has an EMPTY root div - un-prerendered SPA shell"
  fi
  # Presence assertion, not just absence: a file can lose the empty div by being
  # truncated, corrupted, or replaced by an error page. Require positive evidence.
  if ! grep -qi '<title[^>]*>[^<]\+</title>' "$APEX"; then
    bad "index.html has no non-empty <title> - not a rendered document"
  fi
fi

# --- 2. every manifest route has a prerendered document (manifest -> disk) -----
missing=0
for r in "${ROUTES[@]}"; do
  [ "$r" = "/" ] && continue
  f="$ROOT${r}/index.html"
  if [ ! -s "$f" ]; then bad "route $r -> no index.html"; missing=$((missing+1)); continue; fi
  if grep -q '<div id="root"></div>' "$f"; then bad "route $r -> EMPTY root div"; fi
  if ! grep -qi '<title[^>]*>[^<]\+</title>' "$f"; then bad "route $r -> no non-empty <title>"; fi
done
note "routes checked: $(( ${#ROUTES[@]} - 1 )) (apex checked separately), missing: $missing"

# --- 3. the other direction: no prerendered route dir absent from the manifest -
# A stray route dir means the manifest and the build have diverged. That is the
# drift alarm; without it the manifest can silently fall behind ROUTES.
strays=0
while IFS= read -r d; do
  rel="${d#$ROOT}"; rel="${rel%/index.html}"
  [ -z "$rel" ] && continue
  case "$rel" in /assets*) continue;; esac
  hit=0; for r in "${ROUTES[@]}"; do [ "$r" = "$rel" ] && hit=1 && break; done
  if [ "$hit" -eq 0 ]; then bad "prerendered dir not in manifest: $rel"; strays=$((strays+1)); fi
done < <(find "$ROOT" -mindepth 2 -name index.html -not -path '*/.*' 2>/dev/null)
note "stray route dirs: $strays"

# --- verdict ------------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
  echo "PASS: artifact looks prerendered and complete (${#ROUTES[@]} routes)."
  exit 0
fi
if [ "$MODE" = "report" ]; then
  echo "REPORT-ONLY: failures above did NOT block this deploy (ARTIFACT_GATE_MODE=report)."
  exit 0
fi
echo "REFUSED: artifact failed the gate. Rollback lever: clear the service Build Command."
exit 1
