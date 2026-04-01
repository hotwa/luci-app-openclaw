#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

WEB_PTY="$REPO_ROOT/root/usr/share/openclaw/web-pty.js"
OC_CONFIG="$REPO_ROOT/root/usr/share/openclaw/oc-config.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

grep -Fq "const initCmd = urlObj.searchParams.get('cmd') || '';" "$WEB_PTY" || fail "web PTY should read the cmd query parameter"
grep -Fq 'new PtySession(socket, initCmd);' "$WEB_PTY" || fail "web PTY should pass initCmd into PtySession"
grep -Fq "const scriptArgs = this.initCmd ? [SCRIPT_PATH, this.initCmd] : [SCRIPT_PATH];" "$WEB_PTY" || fail "PTY spawner should append the init command when present"
grep -Fq '提示: 微信配置请使用 LuCI 界面「微信配置」菜单' "$OC_CONFIG" || fail "oc-config should point users to the LuCI wechat flow"

echo "ok"
