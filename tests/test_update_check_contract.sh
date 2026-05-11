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
grep -Fq "fetch_release_metadata_from_api" "$CONTROLLER" || fail "update check should still probe release APIs for structured metadata"
grep -Fq "fetch_release_tag_from_redirect" "$CONTROLLER" || fail "update check should fall back to release redirect pages when APIs are unavailable"
grep -Fq "url_effective" "$CONTROLLER" || fail "update check should inspect the final redirect URL to recover the latest tag"
grep -Fq 'local GITEA_REPO = "group/luci-app-openclaw"' "$CONTROLLER" || fail "update check should use the group Gitea mirror repo"
grep -Fq "GITEA_API_RELEASES_URL" "$CONTROLLER" || fail "update check should define a Gitea API fallback"
grep -Fq "GITEA_RELEASES_URL" "$CONTROLLER" || fail "update check should define a Gitea release-page fallback"
grep -Fq "{ api = GITHUB_API_RELEASES_URL, releases = GITHUB_RELEASES_URL }" "$CONTROLLER" || fail "update check should try GitHub first"
grep -Fq "{ api = GITEA_API_RELEASES_URL, releases = GITEA_RELEASES_URL }" "$CONTROLLER" || fail "update check should fall back to Gitea"
grep -Fq "compare_plugin_versions(tag, plugin_latest) > 0" "$CONTROLLER" || fail "update check should keep the highest version discovered across fallback sources"

if grep -Fq 'plugin_current ~= plugin_latest' "$CONTROLLER"; then
	fail "update check should not treat any version mismatch as an upgrade"
fi

echo "ok"
