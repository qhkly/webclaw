# Hermes 安装问题修复总结

## 问题描述

Hermes 安装后无法打开，表现为：
1. Supervisor 显示 `ERROR (no such process)`
2. 端口 10011 未监听
3. 桌面图标仍然是安装命令而非启动命令

## 根本原因

`install-hermes.sh` 脚本在被 `webclaw-app-launcher` 调用时设置了 `DISABLE_ZENITY=1` 环境变量，但脚本没有处理这个模式，导致：

1. **所有安装步骤被跳过** - zenity 进度条逻辑被禁用，但没有替代执行路径
2. **Supervisor 配置未创建** - `/etc/supervisor/conf.d/supervisor-hermes.conf` 不存在
3. **桌面图标未更新** - 图标仍显示安装命令而非启动命令

## 解决方案

### 1. 重构 install-hermes.sh

将安装步骤拆分为独立函数，支持两种模式：

```bash
# 安装步骤函数
install_step_1_dependencies() { ... }
install_step_2_clone() { ... }
install_step_3_setup() { ... }
install_step_4_config() { ... }
install_step_5_start() { ... }

# 主安装函数
install_progress() {
    if [ "${DISABLE_ZENITY:-}" = "1" ]; then
        # 无进度条模式 - 直接执行
        install_step_1_dependencies
        install_step_2_clone
        install_step_3_setup
        install_step_4_config
        install_step_5_start
        return 0
    fi

    # 正常模式 - 使用 zenity 进度条
    {
        echo "10"; echo "# 安装 Python 依赖..."
        install_step_1_dependencies
        ...
    } | zenity --progress ...
}
```

### 2. 关键修复点

| 问题 | 修复 |
|------|------|
| Supervisor 配置未创建 | install_step_4_config 中创建配置文件 |
| 桌面图标未更新 | 安装成功后更新为启动命令 |
| 进度条冲突 | 检测 DISABLE_ZENITY 环境变量 |

### 3. 热部署脚本

创建了 `scripts/hot-deploy.sh` 一键热部署脚本：

```bash
# 部署所有脚本 + 清理 + 验证
./scripts/hot-deploy.sh --all --clean --verify

# 仅部署 Hermes 相关脚本
./scripts/hot-deploy.sh --hermes --clean
```

## 测试验证

### 安装测试

```bash
# 通过 webclaw-app-launcher 安装
WEBCLAW_APP_LAUNCHER=1 DISABLE_ZENITY=1 /usr/local/bin/webclaw-app-launcher install hermes

# 验证 Supervisor 状态
supervisorctl status hermes
# 输出: hermes RUNNING pid xxx, uptime 0:00:00

# 验证端口监听
netstat -tlnp | grep 10011
# 输出: tcp  0  0 0.0.0.0:10011  ...

# 验证 HTTP 访问
curl -I http://127.0.0.1:10011
# 输出: HTTP/1.1 200 OK
```

### 桌面图标测试

```bash
# 检查图标内容
cat /home/ubuntu/Desktop/hermes.desktop
# Exec=/opt/hermes-browser.sh  ✅ 正确

# 测试打开
/opt/hermes-browser.sh
# 应该在浏览器中打开 http://127.0.0.1:10011
```

## 文件变更

| 文件 | 变更 |
|------|------|
| `scripts/install-hermes.sh` | 重构，支持 DISABLE_ZENITY 模式 |
| `scripts/hot-deploy.sh` | 新增，一键热部署工具 |
| `scripts/README-hot-deploy.md` | 新增，热部署使用文档 |
| `configs/supervisord.conf` | 无变更（Hermes 不预装） |

## Git 提交

```
ccf9714 修复: Hermes 安装脚本支持无进度条模式
32ff5b5 新增: 一键热部署脚本
77e775a 修复: 解决热部署脚本提前退出的问题
cff6253 文档: 添加热部署脚本使用指南
```

## 下次构建镜像

重新构建镜像即可包含所有修复：

```bash
cd webclaw-docker
docker build -t webclaw:latest .
```

新镜像将包含：
- ✅ 修复后的 install-hermes.sh
- ✅ 热部署工具（用于开发调试）

## 使用说明

### 用户安装 Hermes

1. 双击桌面上的 **Hermes 智能体** 图标
2. 确认安装对话框
3. 等待安装完成（显示 5 个进度阶段）
4. 自动打开 Web Dashboard

### 开发者调试

```bash
# 修改脚本后快速测试
vim scripts/install-hermes.sh
./scripts/hot-deploy.sh --hermes --clean

# 查看实时日志
docker exec webclaw-inst-xxx tail -f /tmp/hermes_stderr.log
```

## 总结

✅ **问题已完全解决**：
- Hermes 安装脚本现在正确支持无进度条模式
- Supervisor 配置自动创建
- 桌面图标正确更新
- 服务自动启动并监听端口
- 一键热部署工具加速开发调试
