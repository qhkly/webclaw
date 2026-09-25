#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
#  runtime-catalog.sh —— 运行时软件目录（runtime catalog）的共享定义与校验。
#  安装位置：/usr/local/lib/webclaw/runtime-catalog.sh（root:root 0644）
#  使用者：webclaw-catalog-update（拉取/校验/落盘）、webclaw-app-admin（叠加到本地策略）。
#  两者都以 root 运行，source 之前各自确认本文件及其上级目录 root 所有、不可被他人写。
#
#  信任划分：
#    - /opt/on-demand-apps/<id>.json（root 所有，随镜像发布）= 安装策略：install_method、
#      package、binary、install_script、github_repo、download_url… 以及允许的下载来源。
#    - 远程 runtime-catalog.json = 高频变化的事实：version、每架构 artifact 的 url + sha256。
#  校验保证远程只能给「已知 app」提供上面三类事实，而且 url 必须落在本地策略允许的来源内；
#  任何多余字段（install_method、install_script、path…）都会让整份 catalog 被拒绝。
# ─────────────────────────────────────────────────────────────────────

# 下面的常量由 source 本文件的脚本使用。
# shellcheck disable=SC2034
{
# 固定远程地址：不从参数、环境变量或任何可写文件读取。
WEBCLAW_CATALOG_URL="https://raw.githubusercontent.com/qhkly/webclaw-software-manager/main/runtime-catalog.json"
WEBCLAW_CATALOG_SCHEMA=1
WEBCLAW_CATALOG_DIR=/var/lib/webclaw/catalog
WEBCLAW_CATALOG_FILE="$WEBCLAW_CATALOG_DIR/runtime-catalog.json"
WEBCLAW_CATALOG_STATE="$WEBCLAW_CATALOG_DIR/state.json"
# 可选的 detached 签名：公钥存在（root 所有）时，签名变成强制项；不存在时不校验签名。
WEBCLAW_CATALOG_PUBKEY=/etc/webclaw/runtime-catalog.pub
WEBCLAW_CATALOG_SIG_URL="${WEBCLAW_CATALOG_URL}.sig"
# 安装记录（非 dpkg 安装的应用靠它回答 status 的 installed_version）。
WEBCLAW_INSTALLED_DIR=/var/lib/webclaw/installed
WEBCLAW_CATALOG_MAX_BYTES=1048576
}

# /opt 下是系统目录的名字：即便有同名 manifest 也不能当 app_id。
webclaw_reserved_app_id() {
    case "$1" in
        lib|webclaw|nvm-seed|install-scripts|on-demand-apps|on-demand-icons|ondemand-apps|\
        code-server|code-server-extensions|dashboard-override|noVNC|novnc|mihomo|v2rayN|v2rayn|\
        skills|desktop-shortcuts|desktop-icons|containerd|.webclaw-app-admin)
            return 0 ;;
    esac
    return 1
}

webclaw_valid_app_id() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] && [[ "$1" != *..* ]] && ! webclaw_reserved_app_id "$1"
}

# 与 launcher 相同的「按 URL 猜安装包类型」语义（子串匹配，顺序很重要）。
# 输出：deb / tar / zip / appimage
webclaw_artifact_kind() {
    case "$1" in
        *.deb*) echo deb ;;
        *.tar.gz*|*.tgz*) echo tar ;;
        *.zip*) echo zip ;;
        *) echo appimage ;;
    esac
}

# jq 校验程序。
#   输入：远程 catalog（已通过 JSON 解析）。
#   $m：{app_id: manifest}，只包含 root 所有且 app_id 合法的本地 manifest。
#   输出：{errors: [...], ignored: [未知 app_id...], catalog: 规范化后只含已知 app 的 catalog}
# 只要 errors 非空，调用方就必须整份拒绝。
# shellcheck disable=SC2016
WEBCLAW_CATALOG_DEFS='
def rfc3339: type == "string"
    and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})$");
def safe_id: type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$") and (contains("..") | not);
def safe_version: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+~-]{0,63}$");
def sha256hex: type == "string" and test("^[0-9a-f]{64}$");
# 只接受：小写主机名、可选端口、路径里没有空白/反斜杠/#/@ 之类会让解析产生歧义的字符。
def https_url: type == "string" and length <= 2048
    and test("^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/[A-Za-z0-9._~%+=?&,/:!-]*$")
    and (test("/\\.\\.?(/|\\?|&|$)") | not)
    and (test("%(2[eEfF]|5[cC]|00)") | not);
def kind_of: if test("\\.deb") then "deb"
    elif test("\\.tar\\.gz|\\.tgz") then "tar"
    elif test("\\.zip") then "zip"
    else "appimage" end;
def gh_prefix(repo): "https://github.com/" + repo + "/releases/download/";
def valid_repo: type == "string" and test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$");
# 本地字段 → 允许的 URL 前缀（都以 / 结尾，防止 host 前缀拼接绕过）。
# github.com 上只放行某个 repo 的 releases/download/，不放行整个 github.com。
def origin_prefix:
    if test("^https://github\\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/") then
        capture("^(?<p>https://github\\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/releases/download/)").p
    elif test("^https://github\\.com[:/]") then empty
    elif test("^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/") then
        capture("^(?<p>https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/)").p
    else empty end;
def method_of: (.install_method // "github_release");
def allowed_prefixes:
    . as $mf
    | (method_of) as $meth
    | (if ($meth == "github_release" or $meth == "appimage") then
            (if ($mf.github_repo | valid_repo) then [gh_prefix($mf.github_repo)] else [] end)
       elif ($meth == "direct_download" or $meth == "cursor_api" or $meth == "r2_download") then
            [ ($mf.download_url, $mf.version_api, $mf.api_base, $mf.download_api) | strings | origin_prefix ]
            + (if ($mf.github_repo | valid_repo) then [gh_prefix($mf.github_repo)] else [] end)
       else [] end)
    + [ ($mf.catalog_url_prefixes // [])[]? | strings | select(test("^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?/")) ]
    | unique;
# manifest 声明的安装包类型；catalog 不能改变它（deb 应用不能被换成 AppImage，反之亦然）。
def expected_kind:
    (method_of) as $meth
    | if $meth == "github_release" then "deb"
      elif $meth == "appimage" or $meth == "cursor_api" then "appimage"
      elif $meth == "r2_download" then "zip"
      elif $meth == "direct_download" then
          (if (.download_url | type) == "string" then (.download_url | kind_of)
           elif (.jetbrains_code | type) == "string" then "tar"
           else null end)
      else null end;
def artifacts_allowed: (method_of) as $meth
    | ["github_release", "appimage", "direct_download", "cursor_api", "r2_download"] | index($meth) != null;

def check_entry($id; $mf):
    . as $e
    | if (type != "object") then ["apps.\($id): 必须是对象"]
      else
        ([ keys[] | select(. as $k | ["version", "released_at", "artifacts"] | index($k) | not) ]
            | map("apps.\($id): 不允许的字段 \(.)（catalog 只能提供 version/released_at/artifacts）"))
        + (if ($e.version | safe_version) then [] else ["apps.\($id).version: 缺失或非法"] end)
        + (if ($e | has("released_at")) and (($e.released_at | rfc3339) | not) then ["apps.\($id).released_at: 不是 RFC3339"] else [] end)
        + (if ($e | has("artifacts") | not) then []
           elif ($e.artifacts | type) != "object" then ["apps.\($id).artifacts: 必须是对象"]
           elif (($e.artifacts | length) > 0) and ($mf | artifacts_allowed | not) then
               ["apps.\($id).artifacts: 安装方式 \($mf | method_of) 不接受 catalog 下载地址"]
           else
               ($mf | allowed_prefixes) as $pre
               | ($mf | expected_kind) as $kind
               | [ $e.artifacts | to_entries[] | .key as $arch | .value as $a
                   | if (["amd64", "arm64"] | index($arch)) == null then "apps.\($id).artifacts.\($arch): 只支持 amd64/arm64"
                     elif ($a | type) != "object" then "apps.\($id).artifacts.\($arch): 必须是对象"
                     elif ([$a | keys[] | select(. != "url" and . != "sha256")] | length) > 0 then
                         "apps.\($id).artifacts.\($arch): 只允许 url/sha256 字段"
                     elif ($a.url | https_url | not) then "apps.\($id).artifacts.\($arch).url: 必须是规范的 https URL"
                     elif ($a.sha256 | sha256hex | not) then "apps.\($id).artifacts.\($arch).sha256: 必须是 64 位小写十六进制"
                     elif ((($mf.unsupported_archs // []) | index($arch)) != null) then
                         "apps.\($id).artifacts.\($arch): 本地策略声明不支持该架构"
                     elif ($pre | length) == 0 then "apps.\($id).artifacts.\($arch): 本地策略没有声明任何允许的下载来源"
                     elif ([ $pre[] as $p | select($a.url | startswith($p)) ] | length) == 0 then
                         "apps.\($id).artifacts.\($arch).url: 来源不在本地策略允许范围内（允许：\($pre | join(", "))）"
                     elif ($kind != null) and (($a.url | kind_of) != $kind) then
                         "apps.\($id).artifacts.\($arch).url: 安装包类型 \($a.url | kind_of) 与本地策略 \($kind) 不符"
                     else empty end ]
           end)
      end;
'
# shellcheck disable=SC2016
WEBCLAW_CATALOG_JQ="$WEBCLAW_CATALOG_DEFS"'
(if type != "object" then {errors: ["顶层必须是对象"], ignored: [], catalog: null}
 else
    . as $c
    | (([ keys[] | select(. != "schema_version" and . != "generated_at" and . != "apps") ]
        | map("不允许的顶层字段 \(.)"))
      + (if $c.schema_version == 1 and ($c.schema_version | type) == "number" then [] else ["schema_version 必须是 1"] end)
      + (if ($c.generated_at | rfc3339) then [] else ["generated_at 缺失或不是 RFC3339"] end)
      + (if ($c.apps | type) == "object" then [] else ["apps 必须是对象"] end))
      as $top
    | if ($top | length) > 0 then {errors: $top, ignored: [], catalog: null}
      else
        ($c.apps | keys) as $ids
        | [ $ids[] | select(safe_id | not) | "apps 里有非法 app_id：\(.)" ] as $badids
        | [ $ids[] | select(safe_id) | select($m[.] == null) ] as $ignored
        | [ $ids[] | select(safe_id) | select($m[.] != null) ] as $known
        | ($badids + [ $known[] as $id | $c.apps[$id] | check_entry($id; $m[$id])[] ]) as $errs
        | {errors: $errs, ignored: $ignored,
           catalog: {schema_version: 1, generated_at: $c.generated_at,
                     apps: (reduce $known[] as $id ({}; .[$id] = $c.apps[$id]))}}
      end
 end)
'

# 把 root 所有、app_id 合法的 manifest 汇总成 {app_id: manifest}，写到 stdout。
# 不满足条件的 manifest 直接跳过：它们在 broker 里本来就不会被信任。
webclaw_catalog_policies() {
    local dir=/opt/on-demand-apps f id
    local -a files=()
    for f in "$dir"/*.json; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        id="$(basename "$f" .json)"
        webclaw_valid_app_id "$id" || continue
        [ "$(stat -c %u "$f")" = 0 ] || continue
        [ -z "$(find "$f" -maxdepth 0 -perm /022 2>/dev/null)" ] || continue
        files+=("$f")
    done
    if [ "${#files[@]}" -eq 0 ]; then
        echo '{}'
        return 0
    fi
    jq -n 'reduce inputs as $x ({}; .[input_filename | sub(".*/"; "") | sub("\\.json$"; "")] = $x)' "${files[@]}"
}

# 校验 catalog 文件；stdout 输出 {errors, ignored, catalog}。JSON 解析失败时返回非 0。
#   $1 = catalog 文件；$2 = policies 文件（webclaw_catalog_policies 的输出）
webclaw_catalog_validate() {
    jq -c -s --slurpfile pol "$2" "\$pol[0] as \$m
        | if length != 1 then {errors: [\"文件里必须恰好有一个 JSON 值\"], ignored: [], catalog: null}
          else .[0] | $WEBCLAW_CATALOG_JQ end" "$1"
}

# 旧逻辑（manifest 模板 / 版本 API）解析出的下载地址也要落在同一套 source policy 内。
#   $1 = manifest 文件；$2 = URL。
webclaw_url_allowed() {
    jq -e --arg u "$2" "$WEBCLAW_CATALOG_DEFS"'
        allowed_prefixes as $p | ($u | https_url) and ([$p[] | select(. as $x | $u | startswith($x))] | length > 0)' \
        "$1" >/dev/null 2>&1
}
