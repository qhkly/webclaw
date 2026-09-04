# WebCode 备份还原系统

## 功能介绍

WebCode 现在支持完整的容器状态备份和还原功能，类似 Ghost CMS 的备份体验。

### 特性

- ✅ **完整备份** - 备份所有 Docker volumes（项目代码、配置、数据等）
- ✅ **一键还原** - 从备份快速恢复到任意时间点
- ✅ **Web 管理** - 在 Dashboard 中通过点击按钮管理备份
- ✅ **本地存储** - 备份存储在宿主机 `./backups` 目录
- ✅ **自动清理** - 默认保留最近 10 个备份，自动删除旧备份
- ✅ **压缩存储** - 使用 gzip 压缩，节省存储空间

## 备份内容

以下数据会被完整备份：

- `dna-data` - DNA 项目源码
- `projects` - 用户代码项目
- `vibe-kanban-data` - Vibe 看板数据
- `code-server-data` - code-server 配置和设置
- `user-data` - 用户数据
- `openclaw-data` - OpenClaw 配置
- `chrome-data` - Chrome/Chromium 浏览器数据
- `v2rayn-data` - V2rayN 配置
- `gitconfig` - Git 配置
- `recordings` - 录制文件
- `webclaw-config` - WebCode 运行时配置
- `ssh-data` - SSH 密钥与配置
- `servers-data` - 远程服务器工作目录
- `ai-studio-data` - AI Studio 连接与密钥数据
- `skills-data` - 用户自定义技能
- `obsidian-data` - Obsidian 笔记

## 使用方法

### 方法 1: Web 界面（推荐）

1. 访问 WebCode Dashboard: `http://localhost:20000`
2. 点击顶部的 **"备份"** 标签页
3. 点击 **"创建备份"** 按钮创建新备份
4. 在备份列表中可以：
   - 查看所有备份及其大小和创建时间
   - 点击 **"恢复"** 按钮还原到指定备份
   - 点击 **"删除"** 按钮删除不需要的备份

### 方法 2: 命令行

#### 创建备份

```bash
# 在宿主机执行
docker exec -it webcode bash /opt/backup.sh

# 或在容器内执行
docker exec -it webcode bash
bash /opt/backup.sh [备份名称]
```

#### 查看备份

```bash
ls -lh ./backups/
```

#### 恢复备份

```bash
# 在宿主机执行（使用 --force 跳过确认）
docker exec -it webcode bash /opt/restore.sh webclaw-20250308-123456 --force

# 或在容器内执行
docker exec -it webcode bash
bash /opt/restore.sh webclaw-20250308-123456
```

## 备份文件结构

备份文件存储在宿主机的 `./backups` 目录：

```
webclaw-docker/
├── backups/
│   ├── webclaw-20250308-120000.tar.gz    # 备份压缩包
│   ├── webclaw-20250308-120000.json       # 备份元数据
│   ├── webclaw-20250308-130000.tar.gz
│   ├── webclaw-20250308-130000.json
│   └── ...
```

### JSON 元数据格式

```json
{
  "name": "webclaw-20250308-120000",
  "created_at": "2025-03-08T12:00:00+00:00",
  "size": "1.2G",
  "volumes": [
    "dna-data",
    "projects",
    "vibe-kanban-data",
    "code-server-data",
    "user-data",
    "openclaw-data",
    "chrome-data",
    "v2rayn-data",
    "gitconfig",
    "recordings",
    "webclaw-config",
    "ssh-data",
    "servers-data",
    "ai-studio-data",
    "skills-data",
    "obsidian-data"
  ]
}
```

## 配置选项

可以通过环境变量配置备份行为：

```yaml
services:
  webcode:
    environment:
      - BACKUP_DIR=/home/ubuntu/backups    # 备份目录
      - MAX_BACKUPS=10                      # 保留备份数量
```

## 注意事项

⚠️ **恢复备份会覆盖当前所有数据**

- 恢复操作会停止所有服务（code-server、vibe-kanban、openclaw 等）
- 所有当前数据将被备份文件替换
- 恢复完成后服务会自动重启

⚠️ **备份文件存储位置**

- 默认存储在宿主机 `./backups` 目录
- 删除容器不会丢失备份文件（因为是目录挂载，不是 volume）
- 建议定期将 `./backups` 目录复制到其他位置进行异地备份

⚠️ **备份大小**

- 完整备份大小取决于数据量
- 典型大小：500MB - 3GB
- 建议定期清理不需要的备份

## API 接口

如果需要通过 API 操作备份：

### 列出所有备份

```bash
curl http://localhost:20000/api/backup/list
```

### 创建备份

```bash
curl -X POST http://localhost:20000/api/backup/create
```

### 恢复备份

```bash
curl -X POST http://localhost:20000/api/backup/restore/webclaw-20250308-120000
```

### 删除备份

```bash
curl -X DELETE http://localhost:20000/api/backup/delete/webclaw-20250308-120000
```

## 定时备份（可选）

可以使用宿主机的 cron 定时创建备份：

```bash
# 编辑 crontab
crontab -e

# 每天凌晨 2 点自动备份
0 2 * * * cd /path/to/webclaw-docker && docker exec webcode bash /opt/backup.sh
```

## 故障排除

### 备份失败

1. 检查磁盘空间：`df -h`
2. 检查 Docker volumes 是否存在：`docker volume ls`
3. 查看容器日志：`docker logs webcode`

### 恢复失败

1. 确认备份文件完整：`ls -lh ./backups/`
2. 检查 Docker volumes 是否正常
3. 手动停止服务后再试

### Web 界面无备份列表

1. 检查 `./backups` 目录权限
2. 确认容器可以访问该目录：`docker exec webcode ls -la /home/ubuntu/backups`

## 未来计划

- [ ] 支持增量备份（节省空间和时间）
- [ ] 支持云存储（S3、OSS、WebDAV）
- [ ] 支持自动定时备份
- [ ] 支持备份加密
- [ ] 支持备份导出和导入
