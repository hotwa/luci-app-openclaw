#!/bin/sh
# ============================================================================
# 本地构建 .apk 包 (OpenWrt apk v3)
# 用法: sh scripts/build_apk.sh [output_dir]
# ============================================================================
set -e

if ! command -v apk >/dev/null 2>&1; then
	echo "错误: 未检测到 apk 工具链 (apk mkpkg)"
	echo "请先安装 apk-tools，再执行本脚本。"
	exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PKG_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_DIR="${1:-$PKG_DIR/dist}"
case "$OUT_DIR" in
	/*) ;;
	*) OUT_DIR="$PKG_DIR/$OUT_DIR" ;;
esac
mkdir -p "$OUT_DIR"

PKG_NAME="luci-app-openclaw"
PKG_VERSION=$(cat "$PKG_DIR/VERSION" 2>/dev/null | tr -d '[:space:]' || echo "1.0.0")
PKG_RELEASE="1"
APK_VERSION="${PKG_VERSION}-r${PKG_RELEASE}"
APK_FILE="$OUT_DIR/${PKG_NAME}_${APK_VERSION}_all.apk"

echo "=== 构建 ${PKG_NAME} .apk 包 ==="

STAGING=$(mktemp -d)
trap "rm -rf '$STAGING'" EXIT

DATA_DIR="$STAGING/data"
CTRL_DIR="$STAGING/control"
SCRIPT_APK_DIR="$STAGING/apk-scripts"
mkdir -p "$DATA_DIR" "$CTRL_DIR" "$SCRIPT_APK_DIR"

# ── 填充 data 根目录 ──
mkdir -p "$DATA_DIR/etc/config"
cp "$PKG_DIR/root/etc/config/openclaw" "$DATA_DIR/etc/config/"

mkdir -p "$DATA_DIR/etc/uci-defaults"
cp "$PKG_DIR/root/etc/uci-defaults/99-openclaw" "$DATA_DIR/etc/uci-defaults/"
chmod +x "$DATA_DIR/etc/uci-defaults/99-openclaw"

mkdir -p "$DATA_DIR/etc/init.d"
cp "$PKG_DIR/root/etc/init.d/openclaw" "$DATA_DIR/etc/init.d/"
chmod +x "$DATA_DIR/etc/init.d/openclaw"

mkdir -p "$DATA_DIR/etc/profile.d"
cp "$PKG_DIR/root/etc/profile.d/openclaw.sh" "$DATA_DIR/etc/profile.d/"
chmod +x "$DATA_DIR/etc/profile.d/openclaw.sh"

mkdir -p "$DATA_DIR/usr/bin"
cp "$PKG_DIR/root/usr/bin/openclaw-env" "$DATA_DIR/usr/bin/"
chmod +x "$DATA_DIR/usr/bin/openclaw-env"

mkdir -p "$DATA_DIR/usr/libexec"
cp "$PKG_DIR/root/usr/libexec/openclaw-paths.sh" "$DATA_DIR/usr/libexec/"
cp "$PKG_DIR/root/usr/libexec/openclaw-node.sh" "$DATA_DIR/usr/libexec/"
cp "$PKG_DIR/root/usr/libexec/openclaw-compat.sh" "$DATA_DIR/usr/libexec/"
cp "$PKG_DIR/root/usr/libexec/openclaw-wechat.sh" "$DATA_DIR/usr/libexec/"
chmod +x "$DATA_DIR/usr/libexec/openclaw-paths.sh" "$DATA_DIR/usr/libexec/openclaw-node.sh" "$DATA_DIR/usr/libexec/openclaw-compat.sh" "$DATA_DIR/usr/libexec/openclaw-wechat.sh"

mkdir -p "$DATA_DIR/usr/lib/lua/luci/controller"
cp "$PKG_DIR/luasrc/controller/openclaw.lua" "$DATA_DIR/usr/lib/lua/luci/controller/"

mkdir -p "$DATA_DIR/usr/lib/lua/openclaw"
cp "$PKG_DIR/luasrc/openclaw/paths.lua" "$DATA_DIR/usr/lib/lua/openclaw/"

mkdir -p "$DATA_DIR/usr/lib/lua/luci/model/cbi/openclaw"
cp "$PKG_DIR/luasrc/model/cbi/openclaw/"*.lua "$DATA_DIR/usr/lib/lua/luci/model/cbi/openclaw/"

mkdir -p "$DATA_DIR/usr/lib/lua/luci/view/openclaw"
cp "$PKG_DIR/luasrc/view/openclaw/"*.htm "$DATA_DIR/usr/lib/lua/luci/view/openclaw/"

mkdir -p "$DATA_DIR/usr/share/openclaw"
cp "$PKG_DIR/VERSION" "$DATA_DIR/usr/share/openclaw/VERSION"
cp "$PKG_DIR/root/usr/share/openclaw/oc-config.sh" "$DATA_DIR/usr/share/openclaw/"
chmod +x "$DATA_DIR/usr/share/openclaw/oc-config.sh"
cp "$PKG_DIR/root/usr/share/openclaw/"*.js "$DATA_DIR/usr/share/openclaw/"
cp -r "$PKG_DIR/root/usr/share/openclaw/ui" "$DATA_DIR/usr/share/openclaw/"

mkdir -p "$DATA_DIR/usr/lib/lua/luci/i18n"
if command -v po2lmo >/dev/null 2>&1 && [ -f "$PKG_DIR/po/zh-cn/openclaw.po" ]; then
	po2lmo "$PKG_DIR/po/zh-cn/openclaw.po" "$DATA_DIR/usr/lib/lua/luci/i18n/openclaw.zh-cn.lmo" 2>/dev/null || true
fi

# ── 生成升级脚本 (沿用 ipk 逻辑) ──
cat > "$CTRL_DIR/postinst" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	OLD_CONFIG="/etc/config/openclaw"
	NEW_CONFIG="/etc/config/openclaw-opkg"

	if [ -f "$NEW_CONFIG" ]; then
		echo "检测到配置文件冲突，正在智能合并..."
		USER_ENABLED=$(sed -n "s/^\s*option\s\+enabled\s\+['\"]\\?\\([^'\"]*\\)['\"]\\?.*/\\1/p" "$OLD_CONFIG" 2>/dev/null | tail -1)
		USER_PORT=$(sed -n "s/^\s*option\s\+port\s\+['\"]\\?\\([^'\"]*\\)['\"]\\?.*/\\1/p" "$OLD_CONFIG" 2>/dev/null | tail -1)
		USER_BIND=$(sed -n "s/^\s*option\s\+bind\s\+['\"]\\?\\([^'\"]*\\)['\"]\\?.*/\\1/p" "$OLD_CONFIG" 2>/dev/null | tail -1)
		USER_TOKEN=$(sed -n "s/^\s*option\s\+token\s\+['\"]\\?\\([^'\"]*\\)['\"]\\?.*/\\1/p" "$OLD_CONFIG" 2>/dev/null | tail -1)
		USER_PTY_PORT=$(sed -n "s/^\s*option\s\+pty_port\s\+['\"]\\?\\([^'\"]*\\)['\"]\\?.*/\\1/p" "$OLD_CONFIG" 2>/dev/null | tail -1)

		BAK_FILE="/etc/config/openclaw.$(date +%Y%m%d%H%M%S).bak"
		cp "$OLD_CONFIG" "$BAK_FILE" 2>/dev/null || true
		echo "旧配置已备份到: $BAK_FILE"

		mv "$NEW_CONFIG" "$OLD_CONFIG" 2>/dev/null || cp "$NEW_CONFIG" "$OLD_CONFIG" 2>/dev/null || true
		rm -f "$NEW_CONFIG" 2>/dev/null || true

		[ -n "$USER_ENABLED" ] && sed -i "s/^\(\s*option\s\+enabled\s\+\).*/\\1'$USER_ENABLED'/" "$OLD_CONFIG" 2>/dev/null || true
		[ -n "$USER_PORT" ] && sed -i "s/^\(\s*option\s\+port\s\+\).*/\\1'$USER_PORT'/" "$OLD_CONFIG" 2>/dev/null || true
		[ -n "$USER_BIND" ] && sed -i "s/^\(\s*option\s\+bind\s\+\).*/\\1'$USER_BIND'/" "$OLD_CONFIG" 2>/dev/null || true
		[ -n "$USER_TOKEN" ] && sed -i "s/^\(\s*option\s\+token\s\+\).*/\\1'$USER_TOKEN'/" "$OLD_CONFIG" 2>/dev/null || true
		[ -n "$USER_PTY_PORT" ] && sed -i "s/^\(\s*option\s\+pty_port\s\+\).*/\\1'$USER_PTY_PORT'/" "$OLD_CONFIG" 2>/dev/null || true
		echo "配置合并完成，用户设置已保留"
	fi

	if [ -f /etc/uci-defaults/99-openclaw ]; then
		( . /etc/uci-defaults/99-openclaw ) && rm -f /etc/uci-defaults/99-openclaw
	fi

	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* /tmp/luci-indexcache.*.json 2>/dev/null
	PTY_PID=$(pgrep -f 'web-pty.js' 2>/dev/null | head -1)
	[ -n "$PTY_PID" ] && kill "$PTY_PID" 2>/dev/null || true
	exit 0
}
EOF
chmod +x "$CTRL_DIR/postinst"

cat > "$CTRL_DIR/prerm" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	if [ -f /etc/config/openclaw ]; then
		cp /etc/config/openclaw /etc/config/openclaw.pre-upgrade.bak 2>/dev/null || true
	fi
}
EOF
chmod +x "$CTRL_DIR/prerm"

cat > "$CTRL_DIR/postrm" << 'EOF'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null
	if [ "$1" = "0" ]; then
		rm -f /etc/config/openclaw.user.bak /etc/config/openclaw.pre-upgrade.bak 2>/dev/null
	fi
}
EOF
chmod +x "$CTRL_DIR/postrm"

cat > "$CTRL_DIR/conffiles" << 'EOF'
/etc/config/openclaw
EOF

# ── 生成 apk 元数据文件 ──
mkdir -p "$DATA_DIR/lib/apk/packages"
(cd "$DATA_DIR" && find . \( -type f -o -type l \) | sed 's#^\./#/#' | sort > "$DATA_DIR/lib/apk/packages/${PKG_NAME}.list")

cp "$CTRL_DIR/conffiles" "$DATA_DIR/lib/apk/packages/${PKG_NAME}.conffiles"
: > "$DATA_DIR/lib/apk/packages/${PKG_NAME}.conffiles_static"
while IFS= read -r conf_path || [ -n "$conf_path" ]; do
	[ -n "$conf_path" ] || continue
	rel_path="${conf_path#/}"
	[ -f "$DATA_DIR/$rel_path" ] || continue
	csum=$(sha256sum "$DATA_DIR/$rel_path" | awk '{print $1}')
	echo "/$rel_path $csum" >> "$DATA_DIR/lib/apk/packages/${PKG_NAME}.conffiles_static"
done < "$DATA_DIR/lib/apk/packages/${PKG_NAME}.conffiles"

cp "$CTRL_DIR/postinst" "$SCRIPT_APK_DIR/post-install"
cp "$CTRL_DIR/postinst" "$SCRIPT_APK_DIR/post-upgrade"
cp "$CTRL_DIR/prerm" "$SCRIPT_APK_DIR/pre-deinstall"
cp "$CTRL_DIR/postrm" "$SCRIPT_APK_DIR/post-deinstall"
chmod 0755 "$SCRIPT_APK_DIR/post-install" "$SCRIPT_APK_DIR/post-upgrade" "$SCRIPT_APK_DIR/pre-deinstall" "$SCRIPT_APK_DIR/post-deinstall"

APK_DEPENDS="luci-compat luci-base curl openssl-util script-utils tar libstdcpp"
rm -f "$APK_FILE"

apk mkpkg \
	-I "name:${PKG_NAME}" \
	-I "version:${APK_VERSION}" \
	-I "description:OpenClaw AI 网关 LuCI 管理插件" \
	-I "arch:noarch" \
	-I "license:GPL-3.0" \
	-I "origin:https://github.com/10000ge10000/luci-app-openclaw" \
	-I "maintainer:10000ge10000 <10000ge10000@users.noreply.github.com>" \
	-I "url:https://github.com/10000ge10000/luci-app-openclaw" \
	-I "depends:${APK_DEPENDS}" \
	-s "post-install:$SCRIPT_APK_DIR/post-install" \
	-s "post-upgrade:$SCRIPT_APK_DIR/post-upgrade" \
	-s "pre-deinstall:$SCRIPT_APK_DIR/pre-deinstall" \
	-s "post-deinstall:$SCRIPT_APK_DIR/post-deinstall" \
	-F "$DATA_DIR" \
	-o "$APK_FILE"

APK_SIZE=$(wc -c < "$APK_FILE" | tr -d ' ')
INSTALLED_SIZE=$(du -sk "$DATA_DIR" | awk '{print $1}')

echo ""
echo "=== 构建完成 ==="
echo "输出文件: $APK_FILE"
echo "文件大小: ${APK_SIZE} bytes"
echo "安装大小: ${INSTALLED_SIZE} KB"
echo ""
echo "安装方法: apk add --allow-untrusted ${PKG_NAME}_${APK_VERSION}_all.apk"
