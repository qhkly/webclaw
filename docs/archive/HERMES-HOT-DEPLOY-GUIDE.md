# Hermes 热部署完整指南

## 快速开始

### 一键部署（推荐）

```bash
# 部署所有脚本 + 清理 + 验证
./scripts/hot-deploy.sh --all --clean --verify
```

### 仅部署 Hermes

```bash
# 部署 Hermes 相关脚本和配置
./scripts/hot-deploy.sh --hermes --clean
```

## 部署内容

### 脚本文件

| 脚本 | 路径 | 说明 |
|------|------|------|
| install-hermes.sh | /opt/install-hermes.sh | Hermes 安装脚本 |
| webclaw-app-launcher.sh | /usr/local/bin/webclaw-app-launcher | 通用按需安装调度器 |
| update-desktop-icons.sh | /usr/local/bin/update-desktop-icons | 桌面图标更新工具 |
| startup.sh | /opt/startup.sh | 容器启动脚本 |

### 配置文件

| 配置 | 路径 | 说明 |
|------|------|------|
| hermes.json | /opt/on-demand-apps/hermes.json | Hermes 应用清单 |

### 图标文件

| 图标 | 路径 | 说明 |
|------|------|------|
| hermes.png | /opt/desktop-icons/hermes.png | 桌面图标 |
| hermes.png | /opt/on-demand-icons/hermes.png | 应用菜单图标 |

## 安装 Hermes

### 方式 1：桌面安装（推荐）

1. 双击桌面上的 **Hermes 智能体** 图标
2. 确认安装对话框
3. 等待安装完成（5个进度阶段）
4. 自动打开 Web Dashboard

### 方式 2：命令行安装

```bash
# 在容器中运行
WEBCLAW_APP_LAUNCHER=1 /usr/local/bin/webclaw-app-launcher install hermes
```

## 安装进度

安装过程会显示 **5 个明确的进度阶段**：

| 进度 | 阶段 | 说明 |
|------|------|------|
| 10% | 开始安装 | 初始化安装环境 |
| 30% | 准备安装环境 | 更新系统、安装依赖 |
| 50% | 下载 Hermes 文件 | 克隆代码库 |
| 70% | 配置 Hermes 环境 | 创建虚拟环境、安装 Python 包 |
| 90% | 完成 | 创建快捷方式、配置启动项 |

## 卸载 Hermes

### 方式 1：应用菜单

```
Applications → Uninstall Installed Apps → Uninstall Hermes Agent
```

### 方式 2：桌面右键

```
右键桌面 Hermes 图标 → Uninstall Hermes
```

### 方式 3：命令行

```bash
/opt/uninstall-hermes.sh
```

## 验证部署

运行热部署脚本时会自动验证：

```bash
./scripts/hot-deploy.sh --verify
```

验证项目：
- ✅ 脚本文件可执行
- ✅ 包含环境变量检测
- ✅ 包含进度反馈改进
- ✅ 配置文件存在
- ✅ 图标文件存在

## 故障排除

### 问题：图标不显示

```bash
# 刷新桌面图标数据库
/usr/local/bin/update-desktop-icons

# 重启桌面面板
killall -USR1 gnome-panel
```

### 问题：安装卡住

```bash
# 清理安装状态后重新安装
./scripts/hot-deploy.sh --hermes --clean
```

### 问题：服务未启动

```bash
# 检查服务状态
sudo supervisorctl status hermes

# 手动启动服务
sudo supervisorctl start hermes
```

## 热部署选项

| 选项 | 说明 |
|------|------|
| `--all` | 部署所有脚本（默认） |
| `--hermes` | 仅部署 Hermes 相关 |
| `--app-launcher` | 仅部署 app-launcher |
| `--startup` | 仅部署 startup.sh |
| `--clean` | 清理安装状态 |
| `--verify` | 部署后验证 |

## 示例

```bash
# 部署所有脚本
./scripts/hot-deploy.sh --all

# 部署所有脚本并清理
./scripts/hot-deploy.sh --all --clean

# 部署所有脚本并验证
./scripts/hot-deploy.sh --all --verify

# 完整部署（清理+验证）
./scripts/hot-deploy.sh --all --clean --verify

# 仅部署 Hermes
./scripts/hot-deploy.sh --hermes

# 部署到指定容器
./scripts/hot-deploy.sh webclaw-inst-xxx --all
```

## 技术细节

### 环境变量

- `WEBCLAW_APP_LAUNCHER=1` - 告诉脚本由 webclaw-app-launcher 调用
- `DISABLE_ZENITY=1` - 禁用 zenity 进度条（用于进度反馈改进）

### 安装方法

Hermes 使用 `custom_script` 安装方法：
- 安装脚本：`/opt/install-hermes.sh`
- 卸载脚本：`/opt/uninstall-hermes.sh`
- 二进制路径：`/opt/hermes-agent/venv/bin/hermes`

### Supervisor 配置

安装后自动创建 Supervisor 配置：
- 配置文件：`/etc/supervisor/conf.d/supervisor-hermes.conf`
- 服务名：`hermes`
- 端口：`10011`

## 相关文档

- **热部署使用**: `scripts/README-hot-deploy.md`
- **修复总结**: `HERMES-INSTALLATION-FIX.md`
- **帮助信息**: `./scripts/hot-deploy.sh --help`

## Git 提交记录

```
7a15aa3 修复: 热部署脚本添加 Hermes 配置和图标部署
c630a22 优化: 热部署同时部署 update-desktop-icons.sh
c4e9e33 修复: Hermes 卸载快捷方式创建问题
ccf9714 修复: Hermes 安装脚本支持无进度条模式
32ff5b5 新增: 一键热部署脚本
```

## 总结

✅ 热部署脚本现在包含：
- 所有必需的脚本文件
- Hermes 配置文件
- 图标文件
- 自动验证功能

下次构建镜像将自动包含所有改进！
