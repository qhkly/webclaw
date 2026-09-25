# 运行时软件目录（runtime catalog）v1

目标：镜像低频更新，第三方软件高频热更新。软件的版本、下载地址和 sha256 来自远程 catalog，新版本不需要重打镜像。

## 信任划分

| 来源 | 内容 | 谁能改 |
|---|---|---|
| `/opt/on-demand-apps/<id>.json`（root 所有，随镜像发布） | 安装策略：`install_method`、`package`、`binary`、`install_script`、`github_repo`、`download_url`、`catalog_url_prefixes`、`upgrade_by_reinstall` 等 | 只能通过发新镜像修改 |
| 远程 `runtime-catalog.json` | 事实数据：`version`、`released_at`、每个架构 artifact 的 `url` 和 `sha256` | 可以热更新 |

catalog 只能给**本地已有 manifest 的 app** 叠加上面三类事实。它不能新增 app，也不能改安装方式、包名、脚本或目标路径。

## 远程契约（schema v1）

固定 URL：`https://raw.githubusercontent.com/qhkly/webclaw-software-manager/main/runtime-catalog.json`

```json
{
  "schema_version": 1,
  "generated_at": "2026-09-25T00:00:00Z",
  "apps": {
    "<app_id>": {
      "version": "1.2.3",
      "released_at": "2026-09-20T08:00:00+08:00",
      "artifacts": {
        "amd64": {"url": "https://...", "sha256": "<64 位小写 hex>"},
        "arm64": {"url": "https://...", "sha256": "<64 位小写 hex>"}
      }
    }
  }
}
```

校验规则（任何一条不满足就整份拒绝，旧 cache 保持不变）：

- 解析严格：只能有一个 JSON 值。顶层只允许 `schema_version`、`generated_at`、`apps`；条目只允许 `version`、`released_at`、`artifacts`；artifact 只允许 `url`、`sha256`。
- `schema_version` 必须是数字 1。`generated_at` 必须是 RFC3339，不能早于当前 cache（防回滚），也不能超前本机时间 24 小时以上（防冻结）。
- app_id 匹配 `^[a-z0-9][a-z0-9._-]{0,63}$`。本地没有 manifest 的 app 会被丢弃，不写进 cache。
- URL 必须是 https，host 为小写，不含 userinfo、`#`、`..`、`%2e`、`%2f`。URL 必须以本地策略允许的前缀开头：
  - `github_release` / `appimage`：`https://github.com/<github_repo>/releases/download/`
  - `direct_download` / `cursor_api` / `r2_download`：取 `download_url`、`version_api`、`api_base`、`download_api` 的来源（如果是 GitHub，只放行该 repo 的 releases 路径），再加上 manifest 的 `catalog_url_prefixes`。
- 安装包类型（deb / tar / zip / AppImage）必须和 manifest 一致。
- `apt` 和 `custom_script` 只能提供 `version`，不能提供下载地址。
- 本地 `unsupported_archs` 里的架构不能出现在 artifacts 里。

broker 每次使用 catalog 前，都会按当前 manifest 把对应条目重新校验一遍。

## 组件

- `/usr/local/bin/webclaw-catalog-update [--if-stale]`：只能以 root 运行，不在 sudoers 里。它用 flock 串行执行，下载到 root 私有目录，校验通过后原子替换 `/var/lib/webclaw/catalog/runtime-catalog.json`（root:root 0644），并把结果写进 `state.json`。startup 启动一个非阻塞的轻量后台循环，每 15 分钟调用一次 `--if-stale`；updater 自己做节流，6 小时内成功过、或 10 分钟内尝试过就直接跳过，因此绝大多数循环不会联网。单次失败不会结束循环，离线也不影响桌面启动和安装。
- `/usr/local/bin/webclaw-app-admin`（broker）的高层 API（api_version 2）：
  - `api-version`、`catalog-info`、`status <id>`：只读，输出 JSON。
  - `install <id>`、`upgrade <id>`、`uninstall <id>`：端到端执行。退出码 3 表示 unsupported，原因写在 stderr。
  - `status` 的顶层字段：`supported`、`message`、`installed`、`installed_version`、`latest_version`、`update_available`、`upgrade_supported`、`catalog_state`（fresh / stale / offline / unavailable），另外保留嵌套的 `catalog`。
- 归档类应用（AppImage / zip / tar）的安装流程：
  1. root 下载安装包；来自 catalog 的包强制校验 sha256，不匹配就拒绝安装。
  2. 系统用户 `webclaw-unpack` 在 `/var/lib/webclaw/unpack/<随机目录>` 里解包（该目录为 root:webclaw-unpack 0710）。
  3. root 杀掉这个用户的残留进程，校验文件树（属主、硬链接、特殊文件、越界符号链接），再装进受管目录。整个过程中 root 从不执行、也不解析下载内容。
- `custom_script` 的升级：只有 manifest 声明了 `upgrade_by_reinstall: true`，broker 才会重新执行同一个 root 所有的安装脚本（目前是 qq、telegram、discord）。其它 custom_script 应用的 `upgrade_supported` 为 false。
- 所有 mutating 动作都由 `/run/webclaw-app-admin/mutation.lock`（目录 root:root 0700）串行。broker 在 `flock -o` 下重新执行自己，所以 apt postinst 或安装脚本启动的常驻进程不会继承这把锁。

## 签名 hook（预留，默认关闭）

如果存在 `/etc/webclaw/runtime-catalog.pub`（必须 root 所有、不可被他人写，ed25519 PEM 公钥），updater 会强制下载 `<固定 URL>.sig`，并用下面的命令校验 detached 签名：

```
openssl pkeyutl -verify -pubin -inkey /etc/webclaw/runtime-catalog.pub -rawin -in runtime-catalog.json -sigfile runtime-catalog.json.sig
```

签名方生成签名的命令：`openssl pkeyutl -sign -inkey <私钥> -rawin -in runtime-catalog.json -out runtime-catalog.json.sig`。**私钥不进仓库，也不进镜像。**

没有配置公钥时，安全性由这几项保证：固定 URL、本地 source policy、sha256、严格 schema。

## 测试

`./test-runtime-catalog.sh`：在容器内起一个本地 HTTPS 服务，冒充固定域名（测试 CA 加 /etc/hosts），再加一个本地 apt 仓库，不需要外网。覆盖 catalog 校验与 last-known-good、sha256、未知 app、source policy、签名、节流、并发锁、broker 高层 API（apt / deb / AppImage / tar / custom_script）以及 launcher 回归。
