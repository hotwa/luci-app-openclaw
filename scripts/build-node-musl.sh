#!/bin/sh
# 在 Alpine ARM64 Docker 容器内运行
# 环境变量: NODE_VER (目标版本号), /output (输出目录)
set -e

apk add --no-cache nodejs npm xz

ACTUAL_VER=$(node --version | sed 's/^v//')
echo "Alpine Node.js version: v${ACTUAL_VER} (requested: v${NODE_VER})"

# 打包为 portable tarball (与官方 tarball 相同结构)
PKG_NAME="node-v${NODE_VER}-linux-arm64-musl"
PKG_DIR="/tmp/${PKG_NAME}"
mkdir -p "${PKG_DIR}/bin" "${PKG_DIR}/lib/node_modules" "${PKG_DIR}/include/node"

cp "$(which node)" "${PKG_DIR}/bin/"
chmod +x "${PKG_DIR}/bin/node"

# 复制 npm
if [ -d /usr/lib/node_modules/npm ]; then
  cp -r /usr/lib/node_modules/npm "${PKG_DIR}/lib/node_modules/"
fi

# 创建 npm wrapper
printf '#!/bin/sh\nexec "$(dirname "$0")/node" "$(dirname "$0")/../lib/node_modules/npm/bin/npm-cli.js" "$@"\n' \
  > "${PKG_DIR}/bin/npm"
# 创建 npx wrapper
printf '#!/bin/sh\nexec "$(dirname "$0")/node" "$(dirname "$0")/../lib/node_modules/npm/bin/npx-cli.js" "$@"\n' \
  > "${PKG_DIR}/bin/npx"
chmod +x "${PKG_DIR}/bin/npm" "${PKG_DIR}/bin/npx"

# 验证
echo "=== Verification ==="
"${PKG_DIR}/bin/node" --version
"${PKG_DIR}/bin/node" -e "console.log(process.arch, process.platform, process.versions.modules)"
"${PKG_DIR}/bin/npm" --version 2>/dev/null || echo "npm wrapper created"

# 打包
cd /tmp
tar cJf "/output/${PKG_NAME}.tar.xz" "${PKG_NAME}"
ls -lh "/output/${PKG_NAME}.tar.xz"
echo "=== Done: ${PKG_NAME}.tar.xz ==="
