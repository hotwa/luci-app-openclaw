#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"
MAKEFILE="$REPO_ROOT/Makefile"
WECHAT_VIEW="$REPO_ROOT/luasrc/view/openclaw/wechat.htm"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

[ -f "$WECHAT_VIEW" ] || fail "wechat view should exist"
grep -Fq 'template("openclaw/wechat")' "$CONTROLLER" || fail "controller should register the wechat page"
grep -Fq 'call("action_wechat_status")' "$CONTROLLER" || fail "controller should expose the wechat status API"
grep -Fq 'call("action_wechat_install")' "$CONTROLLER" || fail "controller should expose the wechat install API"
grep -Fq 'call("action_wechat_login")' "$CONTROLLER" || fail "controller should expose the wechat login API"
grep -Fq 'call("action_wechat_login_status")' "$CONTROLLER" || fail "controller should expose the wechat login status API"
grep -Fq 'call("action_wechat_uninstall")' "$CONTROLLER" || fail "controller should expose the wechat uninstall API"
grep -Fq 'call("action_wechat_check_upgrade")' "$CONTROLLER" || fail "controller should expose the wechat upgrade check API"
grep -Fq 'call("action_wechat_upgrade_plugin")' "$CONTROLLER" || fail "controller should expose the wechat upgrade API"
grep -Fq 'call("action_wechat_logout")' "$CONTROLLER" || fail "controller should expose the wechat logout API"
grep -Fq './luasrc/view/openclaw/wechat.htm' "$MAKEFILE" || fail "package makefile should install the wechat view"

echo "ok"
