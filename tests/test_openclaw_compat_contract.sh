#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

MAKEFILE="$REPO_ROOT/Makefile"
ENV_SCRIPT="$REPO_ROOT/root/usr/bin/openclaw-env"
INIT_SCRIPT="$REPO_ROOT/root/etc/init.d/openclaw"
WECHAT_HELPER="$REPO_ROOT/root/usr/libexec/openclaw-wechat.sh"
COMPAT_HELPER="$REPO_ROOT/root/usr/libexec/openclaw-compat.sh"
OC_CONFIG_SCRIPT="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq 'openclaw-compat.sh' "$MAKEFILE" || fail "package makefile should install the shared compat helper"
grep -Fq 'oc_apply_runtime_compat' "$COMPAT_HELPER" || fail "compat helper should define the runtime repair entry point"
grep -Fq 'fast-string-truncated-width' "$COMPAT_HELPER" || fail "compat helper should patch the emoji-width dependency"
grep -Fq 'pi-tui' "$COMPAT_HELPER" || fail "compat helper should patch the TUI emoji dependency"

grep -Fq 'openclaw-compat.sh' "$ENV_SCRIPT" || fail "installer should source the shared compat helper"
grep -Fq 'oc_apply_runtime_compat' "$ENV_SCRIPT" || fail "installer should repair runtime compatibility after setup and upgrade"

grep -Fq 'openclaw-compat.sh' "$INIT_SCRIPT" || fail "service init should source the shared compat helper"
grep -Fq 'oc_apply_runtime_compat' "$INIT_SCRIPT" || fail "service init should repair runtime compatibility before starting"

grep -Fq 'openclaw-compat.sh' "$WECHAT_HELPER" || fail "wechat helper should source the shared compat helper"
grep -Fq 'oc_apply_runtime_compat' "$WECHAT_HELPER" || fail "wechat helper should repair runtime compatibility before plugin install or upgrade"

if grep -Fq "['qwen-portal-auth','copilot-proxy','google-gemini-cli-auth','minimax-portal-auth'].forEach" "$OC_CONFIG_SCRIPT"; then
	fail "auth plugin bootstrap should no longer auto-enable minimax-portal-auth"
fi

echo "ok"
