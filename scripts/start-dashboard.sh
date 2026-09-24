#!/usr/bin/env bash
set -euo pipefail

OVERRIDE_DIR="${DASHBOARD_OVERRIDE_DIR:-/opt/dashboard-override}"
OVERRIDE_MAIN="${OVERRIDE_DIR}/dashboard-server.js"
OVERRIDE_HTML="${OVERRIDE_DIR}/dashboard.html"
OVERRIDE_FAVICON="${OVERRIDE_DIR}/dashboard-favicon.ico"
PREPARED_MAIN="/tmp/dashboard-server-override.js"

# 双 Node 运行时：dashboard 是 bytenode 字节码，必须跑在构建它的那个系统 Node
# （/usr/local/bin/node，固定 22.22.1）上。显式锁死解释器和 PATH，不管调用方的
# 环境里有没有 ubuntu 的 nvm，都不会被用户 Node 截走。
NODE_BIN="/usr/local/bin/node"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
unset NVM_DIR NVM_BIN NVM_INC

if [ -f "${OVERRIDE_MAIN}" ]; then
  echo "[dashboard] using override source: ${OVERRIDE_MAIN}"

  export NODE_PATH="${OVERRIDE_DIR}/node_modules:/usr/local/lib/node_modules:/usr/local/lib/node_modules/webclaw-dashboard-server/node_modules:/usr/lib/node_modules:/usr/lib/node_modules/webclaw-dashboard-server/node_modules"

  if [ -f "${OVERRIDE_HTML}" ] && [ -f "${OVERRIDE_FAVICON}" ]; then
    OVERRIDE_MAIN="${OVERRIDE_MAIN}" \
    OVERRIDE_HTML="${OVERRIDE_HTML}" \
    OVERRIDE_FAVICON="${OVERRIDE_FAVICON}" \
    PREPARED_MAIN="${PREPARED_MAIN}" \
    "${NODE_BIN}" <<'EOF'
const fs = require('fs');

const sourcePath = process.env.OVERRIDE_MAIN;
const htmlPath = process.env.OVERRIDE_HTML;
const faviconPath = process.env.OVERRIDE_FAVICON;
const outputPath = process.env.PREPARED_MAIN;

let source = fs.readFileSync(sourcePath, 'utf8');
const htmlContent = fs.readFileSync(htmlPath, 'utf8');
const faviconBase64 = fs.readFileSync(faviconPath).toString('base64');

source = source.replace(
  /const DASHBOARD_HTML_CONTENT = null; \/\/ __INLINE_DASHBOARD_HTML__/,
  `const DASHBOARD_HTML_CONTENT = ${JSON.stringify(htmlContent)};`
);

source = source.replace(
  /const FAVICON_CONTENT = null; \/\/ __INLINE_FAVICON__/,
  `const FAVICON_CONTENT = Buffer.from('${faviconBase64}', 'base64');`
);

fs.writeFileSync(outputPath, source, 'utf8');
EOF

    exec "${NODE_BIN}" "${PREPARED_MAIN}"
  fi

  echo "[dashboard] override html/favicon missing, running source directly"
  exec "${NODE_BIN}" "${OVERRIDE_MAIN}"
fi

echo "[dashboard] using packaged server: webclaw-dashboard-server"
export NODE_PATH="/usr/local/lib/node_modules:/usr/lib/node_modules"
exec "${NODE_BIN}" "$(readlink -f /usr/local/bin/webclaw-dashboard-server)"
