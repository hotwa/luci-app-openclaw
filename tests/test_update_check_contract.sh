#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "local function compare_plugin_versions" "$CONTROLLER" || fail "update check should define a dedicated plugin version comparator"
grep -Fq "plugin_has_update = compare_plugin_versions(plugin_latest, plugin_current) > 0" "$CONTROLLER" || fail "update check should only flag upgrades when the latest version is newer"

if grep -Fq 'plugin_current ~= plugin_latest' "$CONTROLLER"; then
	fail "update check should not treat any version mismatch as an upgrade"
fi

echo "ok"
