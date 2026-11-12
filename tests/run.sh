#!/usr/bin/env bash
# One-command check before a deploy or release. Must end with "ALL PASSED".
#   1. Lua syntax of every addon file: luajit -bl rejects Lua 5.3+ syntax but accepts goto and
#      labels, which the client's Lua 5.1 does not, so those are grepped for as well
#   2. the XML file is well-formed
#   3. the TOC lists exactly the Lua and XML files on disk
#   4. every global, C_ function, Enum value, event, frame method, frame type, template and font
#      the addon uses exists in the Forever client's UI source, API docs or global strings
#      (tests/audit_globals.py; skipped, and said so, until `python3 tests/audit_globals.py --fetch`
#      has downloaded them into .cache/)
#   5. the LuaJIT suite: the whole addon under a fake client
set -uo pipefail
cd "$(dirname "$0")/.."

ADDON='!!AddonWeight'
fail=0
skipped=""
say() { printf '%s\n' "$*"; }

say "== Lua syntax"
for file in "$ADDON"/*.lua; do
  if luajit -bl "$file" >/dev/null; then say "  ok    $file"; else say "  FAIL  $file"; fail=1; fi
done
if grep -nE '\bgoto\b|::[A-Za-z_][A-Za-z0-9_]*::' "$ADDON"/*.lua; then
  say "  FAIL  goto or a label: Lua 5.2 syntax the client does not have"; fail=1
else
  say "  ok    no goto or labels"
fi

say "== XML"
for file in "$ADDON"/*.xml; do
  if xmllint --noout "$file"; then say "  ok    $file"; else say "  FAIL  $file"; fail=1; fi
done

say "== TOC file"
listed=$(grep -v '^#' "$ADDON/$ADDON.toc" | tr -d '\r' | sed '/^$/d' | sort)
present=$(cd "$ADDON" && ls *.lua *.xml | sort)
if [ "$listed" = "$present" ]; then
  say "  ok    TOC lists exactly the Lua and XML files on disk"
else
  say "  FAIL  TOC file list and the files on disk differ"; fail=1
fi

say "== every API the addon uses exists in the Forever client"
python3 -B tests/audit_globals.py
case $? in
  0) ;;
  2) skipped="$skipped (API audit skipped)" ;;
  *) fail=1 ;;
esac

say "== tests/test_addon.lua"
luajit tests/test_addon.lua | grep -v '^  PASS' || true
[ "${PIPESTATUS[0]}" -eq 0 ] || fail=1

if [ "$fail" -eq 0 ]; then say "ALL PASSED$skipped"; else say "FAILED"; exit 1; fi
