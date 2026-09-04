# ClaudeCodeUI Platform Mode 免登录配置

本文档说明了如何配置ClaudeCodeUI以Platform模式运行，实现完全免登录访问。

## 修改概述

通过启用Platform模式，ClaudeCodeUI会跳过JWT token验证，直接使用数据库中的第一个用户，实现完全免登录。

## 需要修改的文件

### 1. Dockerfile.base
在构建基础镜像时修改ClaudeCodeUI源代码：

```dockerfile
# 在Dockerfile.base的RUN npm install -g @siteboon/claude-code-ui之后添加：

# Enable Platform mode for ClaudeCodeUI (no authentication required)
RUN sed -i 's/export const IS_PLATFORM = process.env.VITE_IS_PLATFORM === .true.;/export const IS_PLATFORM = true;/' \
    /usr/lib/node_modules/@siteboon/claude-code-ui/server/constants/config.js

# Fix auth status endpoint to return authenticated=true in Platform mode
RUN cp /usr/lib/node_modules/@siteboon/claude-code-ui/server/routes/auth.js \
    /usr/lib/node_modules/@siteboon/claude-code-ui/server/routes/auth.js.bak

# Note: The auth.js patch needs to be applied via a separate script
# See scripts/enable-claudecodeui-platform-mode.sh
```

### 2. 创建脚本文件
创建 `scripts/enable-claudecodeui-platform-mode.sh`:

```bash
#!/bin/bash
# Enable Platform mode for ClaudeCodeUI

AUTH_JS="/usr/lib/node_modules/@siteboon/claude-code-ui/server/routes/auth.js"

# Import IS_PLATFORM from constants/config.js
sed -i 's/import { generateToken, authenticateToken } from/import { generateToken, authenticateToken } from/' "$AUTH_JS"
sed -i "0,/from/s//import { IS_PLATFORM } from \"..\/constants\/config.js\";\nimport { generateToken, authenticateToken } from/" "$AUTH_JS"

# Modify /status endpoint to return isAuthenticated=true in Platform mode
sed -i '/router\.get("\/status"/, /catch (error) {/ {
    /res\.json({/ {
        a\
      let isAuthenticated = false;\
      if (IS_PLATFORM && hasUsers) {\
        isAuthenticated = true;\
      }
    }
    /isAuthenticated: false/ {
        s/isAuthenticated: false/isAuthenticated/
    }
}' "$AUTH_JS"
```

### 3. supervisor-claudecodeui.conf
确保配置文件包含正确的环境变量：

```ini
[program:claudecodeui]
command=/usr/local/bin/claude-code-ui --port 10007
directory=/home/ubuntu/projects
user=ubuntu
environment=HOME="/home/ubuntu",NODE_ENV="production",PORT="10007",JWT_SECRET="%(ENV_JWT_SECRET)s",DATABASE_PATH="/home/ubuntu/.cloudcli/auth.db"
priority=200
autostart=%(ENV_ENABLE_CLAUDECODEUI)s
autorestart=true
startretries=5
startsecs=15
stdout_logfile=/tmp/claudecodeui_stdout.log
stderr_logfile=/tmp/claudecodeui_stderr.log
stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB
```

### 4. startup.sh
确保JWT_SECRET被正确加载（已在之前修改）：

```bash
# Load persisted runtime config
for KEY in AUTH_USER AUTH_PASSWORD VNC_PASSWORD OPENCLAW_GATEWAY_TOKEN JWT_SECRET \
             GIT_USER_NAME GIT_USER_EMAIL CF_TUNNEL_TOKEN \
             ENABLE_KANBAN ENABLE_OPENCLAW ENABLE_CLAUDECODEUI; do
    VAL=$(python3 -c "
import json,sys
try:
  d=json.load(open('$WEBCODE_CFG'))
  print(d.get('$KEY',''),end='')
except: pass
" 2>/dev/null)
    [ -n "$VAL" ] && export "$KEY=$VAL"
done

# Set JWT_SECRET default
export JWT_SECRET="${JWT_SECRET:-changeme-for-production}"
```

## 当前状态

当前运行的容器已通过以下临时修改启用了Platform mode：

1. **config.js**: `IS_PLATFORM = true`
2. **auth.js**: 修改了`/status`端点，在Platform mode下返回`isAuthenticated: true`
3. **环境变量**: 设置了正确的`DATABASE_PATH`

## 验证

测试Platform mode是否正常工作：

```bash
# 应该返回 {"needsSetup":false,"isAuthenticated":true}
curl http://127.0.0.1:10007/api/auth/status

# 应该返回HTML页面（而不是401错误）
curl http://127.0.0.1:10007/api/user
```

## 下一步

要使这些修改永久化，需要在Dockerfile.base中添加相应的修改，然后重新构建镜像。

## 优势

使用Platform mode的好处：
1. 完全免登录，用户体验最佳
2. 不需要管理JWT token
3. 简化了SSO实现
4. 适合单用户环境（如webcode的典型使用场景）

## 注意事项

- Platform mode会跳过所有JWT验证，仅适合可信的单用户环境
- 确保数据库中有一个有效的用户（初始化时会自动创建）
- 如需多用户支持，应使用标准的JWT认证模式
