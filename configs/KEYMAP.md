# noVNC 按键映射配置说明

## 📝 功能概述

解决 noVNC 全屏模式下按 ESC 键会退出全屏的问题，提供可自定义的按键映射方案。

## ⌨️ 默认按键映射

### 单键映射
| 按键 | 功能 | 说明 |
|------|------|------|
| **Pause** | 发送 ESC | 推荐，键盘右上角独立键 |
| **ScrollLock** | 发送 Ctrl+Alt+Del | 推荐，任务管理器 |

### Shift 组合映射
| 组合键 | 功能 | 说明 |
|--------|------|------|
| **Shift+Tab** | 发送 Tab | 避免浏览器快捷键冲突 |
| **Shift+Delete** | 发送 Delete | |
| **Shift+Insert** | 发送 Insert | |
| **Shift+Home** | 发送 Home | |
| **Shift+End** | 发送 End | |
| **Shift+PageUp** | 发送 PageUp | |
| **Shift+PageDown** | 发送 PageDown | |

## 🔧 如何自定义映射

### 方法 1：修改配置文件（推荐）

编辑文件：`configs/key-remap.js`

找到 `MAPPINGS` 配置对象，修改或添加映射：

```javascript
const MAPPINGS = {
  // 单键映射示例
  'Pause': {
    enabled: true,           // 设为 false 可禁用
    type: 'single',          // 单键直接映射
    code: 'Pause',
    targetKeysym: 0xFF1B,    // ESC 的 keysym
    targetName: 'Escape',
    hint: 'Pause → ESC'      // 提示文本
  },

  // Shift 组合映射示例
  'Tab': {
    enabled: true,
    type: 'shift',           // 需要 Shift+Tab
    code: 'Tab',
    targetKeysym: 0xFF09,    // Tab 的 keysym
    targetName: 'Tab',
    hint: 'Shift+Tab → Tab'
  }
};
```

### 方法 2：运行时动态修改（临时）

1. 连接 noVNC
2. 打开浏览器开发者工具（F12）
3. 在控制台输入：

```javascript
// 查看当前所有映射
KEY_REMAP_CONFIG.MAPPINGS

// 禁用某个映射
KEY_REMAP_CONFIG.MAPPINGS['Pause'].enabled = false

// 启用某个映射
KEY_REMAP_CONFIG.MAPPINGS['F9'].enabled = true

// 刷新页面生效
location.reload()
```

## 🎯 常用按键的 keysym 值

| 按键 | Keysym (十六进制) | 说明 |
|------|------------------|------|
| ESC | 0xFF1B | Escape |
| Tab | 0xFF09 | Tab |
| Delete | 0xFFFF | Delete |
| Insert | 0xFF63 | Insert |
| Home | 0xFF50 | Home |
| End | 0xFF57 | End |
| PageUp | 0xFF55 | Page Up |
| PageDown | 0xFF56 | Page Down |
| F1-F12 | 0xFFBE-0xFFC9 | Function keys |

### 组合键的 keysym
| 按键 | Keysym (十六进制) |
|------|------------------|
| Ctrl_L | 0xFFE3 |
| Ctrl_R | 0xFFE4 |
| Alt_L | 0xFFE9 |
| Alt_R | 0xFFEA |
| Shift_L | 0xFFE1 |
| Shift_R | 0xFFE2 |

## 📦 文件结构

```
webclaw-docker/
├── configs/
│   └── key-remap.js          # 按键映射配置文件 ⭐
├── scripts/
│   └── patch-novnc.sh        # 注入脚本到 vnc.html
└── Dockerfile                 # 构建镜像时复制文件
```

## 🚀 部署和测试

### 本地测试（使用 hotreload）

```bash
# 1. 复制修改后的配置文件到容器
docker cp configs/key-remap.js webcode:/opt/noVNC/key-remap.js

# 2. 修改 vnc.html 注入脚本（如果还没注入）
docker exec webcode sed -i 's|<script src="touch-handler.js"></script>|<script src="touch-handler.js"></script><script src="key-remap.js"></script>|' /opt/noVNC/vnc.html

# 3. 刷新浏览器页面（Ctrl+R）
```

### 重新构建镜像

```bash
cd webclaw-docker
docker compose down
docker build -t webcode .
docker compose up -d
```

## 💡 使用技巧

### Vim 用户
如果经常使用 Vim，推荐：
```javascript
'Pause': {  // 或 'CapsLock' 如果键盘支持
  enabled: true,
  type: 'single',
  code: 'Pause',
  targetKeysym: 0xFF1B,
  targetName: 'Escape',
  hint: 'Pause → ESC (Vim mode)'
}
```

### 禁用某个映射
如果某个按键需要正常使用，设为 `enabled: false`：
```javascript
'Tab': {
  enabled: false,  // 禁用 Shift+Tab 映射
  // ...
}
```

## 🐛 调试

启用详细日志：
```javascript
// 在 key-remap.js 中修改
const CONFIG = {
  debug: true,  // 启用调试日志
  // ...
};
```

打开浏览器控制台，查看按键事件：
```
[key-remap] 🔑 Single key: Pause → Escape
[key-remap] Sending: Escape (keysym: 0xFF1B)
```

## ⚠️ 注意事项

1. **不要映射浏览器快捷键**：避免映射 F5（刷新）、F12（开发者工具）等
2. **Shift 组合**：对于普通按键，推荐使用 Shift 组合，避免冲突
3. **单键映射**：仅用于特殊功能键（ESC、Ctrl+Alt+Del）
4. **配置修改后**：需要刷新浏览器页面才能生效

## 🖱️ 触摸 / 鼠标 URL 参数（touch-handler.js）

魔改的 `touch-handler.js` 在触摸设备上启用“触控板模式”（手指相对移动虚拟光标）。可通过 noVNC 地址上的 `touch` 参数控制：

| 参数 | 说明 |
|------|------|
| `?touch=1` | 强制开启触控板模式（调试用；触摸屏笔记本可用） |
| `?touch=0` | 强制关闭：不安装捕获层，仅保留 noVNC 原生鼠标 + 触摸 |
| 不传参数 | 触摸设备自动开启触控板模式 |

**触摸屏电脑（既有触摸又有鼠标）**：捕获层现在会把鼠标 / 滚轮事件转发给 noVNC canvas，因此鼠标点击、移动、右键、滚轮、拖拽均正常，手指触摸同时保留触控板模式；两者可同时使用。若只想用普通鼠标、彻底关掉触控板，在地址后追加 `&touch=0`（经 dashboard 代理时路径为 `/proxy/10004/`，参数照常传递）。

> 改动脚本后浏览器可能缓存旧版 `touch-handler.js`，注入时已带 `?v=` 版本号；如仍未生效可强制刷新。

## 📚 参考资料

- noVNC 官方文档：https://github.com/novnc/noVNC
- RFB 协议 keysym 定义：https://www.x.org/releases/X11R7.7/doc/xproto/keysyms.html
