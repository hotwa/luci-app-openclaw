#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

CONTROLLER="$REPO_ROOT/luasrc/controller/openclaw.lua"
HELPER="$REPO_ROOT/root/usr/libexec/openclaw-wechat.sh"

fail() {
	echo "FAIL: $1" >&2
	exit 1
}

for symbol in \
	wechat_status \
	wechat_install \
	wechat_install_log \
	wechat_login \
	wechat_login_status \
	wechat_check_upgrade \
	wechat_upgrade_plugin \
	wechat_logout \
	wechat_uninstall
do
	grep -Fq "$symbol" "$CONTROLLER" || fail "controller should expose $symbol"
done

grep -Fq "openclaw-wechat.sh" "$CONTROLLER" || fail "controller should invoke the shared wechat helper"
grep -Fq "start-stop-daemon -S -c openclaw" "$CONTROLLER" || fail "controller should drop privileges with start-stop-daemon"
grep -Fq "oc_load_paths" "$HELPER" || fail "helper should reuse the shared path resolver"
grep -Fq "npx" "$HELPER" || fail "helper should call the OpenClaw CLI through npx"

if grep -Fq "su -s /bin/sh openclaw -c" "$CONTROLLER"; then
	fail "controller should not rely on su for wechat actions"
fi

echo "ok"
