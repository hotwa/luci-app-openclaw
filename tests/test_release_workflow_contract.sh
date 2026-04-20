#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

WORKFLOW="$REPO_ROOT/.github/workflows/build.yml"
GITEA_SYNC_SCRIPT="$REPO_ROOT/scripts/sync_gitea_release.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "push:" "$WORKFLOW" || fail "build workflow should trigger on pushed tags"
grep -Fq "tags:" "$WORKFLOW" || fail "build workflow should restrict push trigger to tags"
grep -Fq "'v*'" "$WORKFLOW" || fail "build workflow should react to version tags"
grep -Fq "github.ref_type == 'tag'" "$WORKFLOW" || fail "build workflow should derive release version from pushed tags"
grep -Fq "continue-on-error: true" "$WORKFLOW" || fail "optional Gitea sync should not fail the GitHub release workflow"
grep -Fq "Gitea Release Sync (optional)" "$WORKFLOW" || fail "build workflow should expose an optional Gitea release sync step"
grep -Fq "GITEA_TOKEN" "$WORKFLOW" || fail "build workflow should use a Gitea token secret"
grep -Fq "env.GITEA_TOKEN != ''" "$WORKFLOW" || fail "workflow should gate optional Gitea sync through an environment variable"
grep -Fq "GITEA_TOKEN: \${{ secrets.GITEA_TOKEN }}" "$WORKFLOW" || fail "workflow should map the Gitea secret into job environment"

if grep -Fq "secrets.GITEA_TOKEN != ''" "$WORKFLOW"; then
	fail "workflow should not reference secrets directly inside if conditionals"
fi

[ -f "$GITEA_SYNC_SCRIPT" ] || fail "optional Gitea sync helper script should exist"
grep -Fq "/mirror-sync" "$GITEA_SYNC_SCRIPT" || fail "Gitea sync script should trigger mirror refresh before publishing"
grep -Fq "/releases/tags/" "$GITEA_SYNC_SCRIPT" || fail "Gitea sync script should detect existing releases by tag"
grep -Fq "/releases/" "$GITEA_SYNC_SCRIPT" || fail "Gitea sync script should create or update releases"
grep -Fq "/assets" "$GITEA_SYNC_SCRIPT" || fail "Gitea sync script should upload release assets"

echo "ok"
