#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
. "$SCRIPT_DIR/openclaw-paths.sh"
oc_load_paths "$OPENCLAW_INSTALL_ROOT"

NODE_BIN="${NODE_BASE}/bin/node"
NPX_BIN="${NODE_BASE}/bin/npx"

WECHAT_ROOT="${OC_DATA}/.openclaw"
WECHAT_PLUGIN_DIR="${WECHAT_ROOT}/extensions/openclaw-weixin"
WECHAT_ACCOUNTS_DIR="${WECHAT_ROOT}/openclaw-weixin"
WECHAT_CONFIG_JSON="${WECHAT_ROOT}/openclaw.json"

INSTALL_LOG="/tmp/openclaw-wechat-install.log"
INSTALL_PID="/tmp/openclaw-wechat-install.pid"
INSTALL_EXIT="/tmp/openclaw-wechat-install.exit"
LOGIN_QR="/tmp/openclaw-wechat-qrcode.txt"
LOGIN_PID="/tmp/openclaw-wechat-login.pid"
LOGIN_EXIT="/tmp/openclaw-wechat-login.exit"
RESTART_MARK="/tmp/openclaw-wechat-restarted"
STATE_FILE="/tmp/openclaw-wechat.state"

wechat_find_entry() {
	local search_dirs d

	search_dirs="${OC_GLOBAL}/lib/node_modules/openclaw
${OC_GLOBAL}/node_modules/openclaw
${NODE_BASE}/lib/node_modules/openclaw"

	for ver_dir in "${OC_GLOBAL}"/*/node_modules/openclaw; do
		[ -d "$ver_dir" ] && search_dirs="$search_dirs
$ver_dir"
	done

	for link_dir in "${OC_GLOBAL}/lib/node_modules/openclaw" "${OC_GLOBAL}/node_modules/openclaw"; do
		if [ -L "$link_dir" ]; then
			local real_dir
			real_dir=$(readlink -f "$link_dir" 2>/dev/null || true)
			[ -n "$real_dir" ] && [ -d "$real_dir" ] && search_dirs="$search_dirs
$real_dir"
		fi
	done

	while IFS= read -r d; do
		[ -z "$d" ] && continue
		if [ -f "${d}/openclaw.mjs" ]; then
			printf '%s\n' "${d}/openclaw.mjs"
			return 0
		fi
		if [ -f "${d}/dist/cli.js" ]; then
			printf '%s\n' "${d}/dist/cli.js"
			return 0
		fi
	done <<EOF
$search_dirs
EOF

	return 1
}

wechat_write_state() {
	local action="$1"
	local status="${2:-running}"
	local pid="${3:-$$}"

	cat > "$STATE_FILE" <<EOF
action=$action
status=$status
pid=$pid
updated_at=$(date +%s)
EOF
}

wechat_finish_state() {
	local action="$1"
	local exit_code="${2:-0}"

	cat > "$STATE_FILE" <<EOF
action=$action
status=finished
exit_code=$exit_code
pid=$$
updated_at=$(date +%s)
EOF
}

wechat_install_like() {
	local label="$1"
	local success_message="$2"
	local failure_message="$3"

	rm -f "$INSTALL_LOG" "$INSTALL_PID" "$INSTALL_EXIT"
	wechat_write_state "install"

	{
		printf '%s\n' "$label"
		printf '安装路径: %s\n' "$OC_ROOT"
		printf 'npx 路径: %s\n' "$NPX_BIN"
	} > "$INSTALL_LOG"

	if [ ! -x "$NPX_BIN" ]; then
		printf '❌ 错误: npx 命令不存在 (%s)\n' "$NPX_BIN" >> "$INSTALL_LOG"
		printf '127\n' > "$INSTALL_EXIT"
		wechat_finish_state "install" 127
		return 127
	fi

	mkdir -p "${OC_DATA}/.npm" "${OC_DATA}/.cache/corepack" "${OC_DATA}/tmp" 2>/dev/null || true

	cd "$OC_ROOT"
	rc=0
	HOME="$OC_DATA" \
	OPENCLAW_HOME="$OC_DATA" \
	OPENCLAW_STATE_DIR="$WECHAT_ROOT" \
	OPENCLAW_CONFIG_PATH="$WECHAT_CONFIG_JSON" \
	PATH="${NODE_BASE}/bin:${OC_GLOBAL}/bin:$PATH" \
	"$NPX_BIN" -y @tencent-weixin/openclaw-weixin-cli install >> "$INSTALL_LOG" 2>&1 || rc=$?

	printf '%s\n' "$rc" > "$INSTALL_EXIT"
	if [ "$rc" -eq 0 ]; then
		printf '%s\n' "$success_message" >> "$INSTALL_LOG"
	else
		printf '%s (exit: %s)\n' "$failure_message" "$rc" >> "$INSTALL_LOG"
	fi

	wechat_finish_state "install" "$rc"
	return "$rc"
}

wechat_login() {
	local oc_entry rc

	rm -f "$LOGIN_QR" "$LOGIN_PID" "$LOGIN_EXIT" "$RESTART_MARK"
	wechat_write_state "login"

	oc_entry=$(wechat_find_entry || true)
	if [ -z "$oc_entry" ]; then
		{
			printf '正在启动微信登录...\n'
			printf '安装路径: %s\n' "$OC_ROOT"
			printf '❌ 错误: 未找到 OpenClaw 入口文件\n'
		} > "$LOGIN_QR"
		printf '127\n' > "$LOGIN_EXIT"
		wechat_finish_state "login" 127
		return 127
	fi

	if [ ! -x "$NODE_BIN" ]; then
		{
			printf '正在启动微信登录...\n'
			printf '安装路径: %s\n' "$OC_ROOT"
			printf '❌ 错误: node 命令不存在 (%s)\n' "$NODE_BIN"
		} > "$LOGIN_QR"
		printf '127\n' > "$LOGIN_EXIT"
		wechat_finish_state "login" 127
		return 127
	fi

	{
		printf '正在启动微信登录...\n'
		printf '安装路径: %s\n' "$OC_ROOT"
	} > "$LOGIN_QR"

	cd "$OC_ROOT"
	rc=0
	HOME="$OC_DATA" \
	OPENCLAW_HOME="$OC_DATA" \
	OPENCLAW_STATE_DIR="$WECHAT_ROOT" \
	OPENCLAW_CONFIG_PATH="$WECHAT_CONFIG_JSON" \
	PATH="${NODE_BASE}/bin:${OC_GLOBAL}/bin:$PATH" \
	"$NODE_BIN" "$oc_entry" channels login --channel openclaw-weixin >> "$LOGIN_QR" 2>&1 || rc=$?

	printf '%s\n' "$rc" > "$LOGIN_EXIT"
	if [ "$rc" -ne 0 ]; then
		printf '❌ 登录失败 (exit: %s)\n' "$rc" >> "$LOGIN_QR"
	fi

	wechat_finish_state "login" "$rc"
	return "$rc"
}

wechat_logout() {
	local account_id="$1"
	local oc_entry rc

	oc_entry=$(wechat_find_entry || true)
	if [ -z "$oc_entry" ]; then
		return 127
	fi

	if [ ! -x "$NODE_BIN" ]; then
		return 127
	fi

	cd "$OC_ROOT"
	rc=0
	HOME="$OC_DATA" \
	OPENCLAW_HOME="$OC_DATA" \
	OPENCLAW_STATE_DIR="$WECHAT_ROOT" \
	OPENCLAW_CONFIG_PATH="$WECHAT_CONFIG_JSON" \
	PATH="${NODE_BASE}/bin:${OC_GLOBAL}/bin:$PATH" \
	"$NODE_BIN" "$oc_entry" channels logout --channel openclaw-weixin --account "$account_id" >/dev/null 2>&1 || rc=$?

	wechat_finish_state "logout" "$rc"
	return "$rc"
}

wechat_uninstall() {
	rm -rf "$WECHAT_PLUGIN_DIR" "$WECHAT_ACCOUNTS_DIR" "$INSTALL_LOG" "$INSTALL_PID" "$INSTALL_EXIT" \
		"$LOGIN_QR" "$LOGIN_PID" "$LOGIN_EXIT" "$RESTART_MARK" "$STATE_FILE"
	return 0
}

case "${1:-}" in
	install)
		wechat_install_like "开始安装微信插件..." "✅ 微信插件安装成功！" "❌ 安装失败"
		;;
	login)
		wechat_login
		;;
	logout)
		wechat_logout "${2:-}"
		;;
	uninstall)
		wechat_uninstall
		;;
	upgrade)
		wechat_install_like "正在升级微信插件..." "✅ 微信插件升级成功！" "❌ 升级失败"
		;;
	*)
		printf 'Usage: %s {install|login|logout|uninstall|upgrade}\n' "$0" >&2
		exit 2
		;;
esac
