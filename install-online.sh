#!/usr/bin/env bash
# =============================================================================
#  pve-nodeinfo 一键安装脚本
#  在 Proxmox VE 节点的「摘要」面板中增加  温度 / CPU 频率 / 功耗 / 磁盘健康
#
#  一句话运行（在 PVE 主机上，root 身份）：
#    curl -fsSL https://raw.githubusercontent.com/TAN-GOOD/pve-nodeinfo/main/install-online.sh | bash
#
#  更多用法：
#    bash install-online.sh --doctor      只体检，不改任何东西
#    bash install-online.sh --dry-run     预演安装，不写任何文件
#    bash install-online.sh --force       强制重装（先卸载再装）
#    bash install-online.sh --uninstall   卸载
#    bash install-online.sh --help        查看全部参数
#
#  设计约定：
#    - 全程不需要人工输入，可以直接复制粘贴运行；
#    - 任何一步失败都立即停下，并打印「原因 / 原始错误 / 怎么解决」；
#    - 重复运行安全：同版本直接跳过，不同版本先卸载再装，不会叠加补丁。
#
#  注意：本脚本刻意不启用 set -e。大部分步骤需要「失败后继续判定并给出
#        分行建议」，errexit 会让它半路静默退出，反而不利于排查。
# =============================================================================
set -uo pipefail

REPO="TAN-GOOD/pve-nodeinfo"
DEFAULT_VERSION="1.2.0"
SCRIPT_DATE="2026-11-26"

# 已知版本的 SHA256。正常流程用 GitHub API 返回的 digest 校验，
# 这里只是 API 不可用（限流 / 离线）时的兜底。
declare -A KNOWN_SHA=(
    ["1.2.0"]="aa029551310074d3bd8f66cef2810fbf2b2ab875f72465fa6a8130e51e6a6fb3"
)

NP=/usr/share/perl5/PVE/API2/Nodes.pm
PJS=/usr/share/pve-manager/js/pvemanagerlib.js
CONF_DIR=/etc/pve-nodeinfo
RUNDIR=/run/pve-nodeinfo
UNIT_DIR=/etc/systemd/system
TIMER=pve-nodeinfo-collect.timer
SERVICE=pve-nodeinfo-collect.service
HELPER=/usr/local/bin/pve-hwinfo.sh
COLLECTOR=/usr/local/bin/pve-nodeinfo-collect
SMARTCTL=/usr/sbin/smartctl

# ---------------------------------------------------------------- 参数解析 --
DRY=0
FORCE=0
DOCTOR=0
DO_UNINSTALL=0
MIRROR=0
KEEP=0
USE_COLOR=1
WANT_VERSION=""
PKG_SRC=""

usage() {
    cat <<'EOF'
pve-nodeinfo 一键安装脚本

用法: bash install-online.sh [选项]

选项:
  --doctor          只做环境体检，不下载、不安装、不改任何文件
  --dry-run         预演安装流程，打印将要做什么，不写入任何文件
  --force           即使已装同版本也强制重装（内部先卸载再安装）
  --uninstall       卸载，并把 PVE 界面文件还原到安装前
  --version <版本>  指定安装版本，例如 1.2.0（默认装 GitHub 上的最新版）
  --pkg <路径|URL>  使用自定义发布包，跳过在线下载
  --mirror          主站下载失败时，额外尝试第三方 GitHub 加速镜像
                    （内容仍需通过 SHA256 校验，镜像无法篡改内容）
  --keep            保留下载的临时文件，便于排查问题
  --no-color        关闭彩色输出（便于复制日志）
  -h, --help        显示本帮助

常用示例:
  # 先体检，什么都不改
  bash install-online.sh --doctor

  # 用已验证过的本地包离线安装
  bash install-online.sh --pkg /tmp/pve-nodeinfo-1.2.0.tar.gz

  # 直连 GitHub 很慢时走加速镜像
  bash install-online.sh --mirror

  # 卸载（PVE 升级前必须做）
  bash install-online.sh --uninstall
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY=1 ;;
        --force)          FORCE=1 ;;
        --doctor|--check) DOCTOR=1 ;;
        --uninstall)      DO_UNINSTALL=1 ;;
        --mirror)         MIRROR=1 ;;
        --keep)           KEEP=1 ;;
        --no-color)       USE_COLOR=0 ;;
        --version)        WANT_VERSION="${2:-}"; shift ;;
        --version=*)      WANT_VERSION="${1#*=}" ;;
        --pkg)            PKG_SRC="${2:-}"; shift ;;
        --pkg=*)          PKG_SRC="${1#*=}" ;;
        -h|--help)        usage; exit 0 ;;
        *)                printf '未知参数: %s\n（用 --help 查看支持的参数）\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

# ------------------------------------------------------------------ 输出层 --
if [ "$USE_COLOR" = "1" ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_D=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
else
    C_RST=""; C_B=""; C_D=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""
fi

STEP_NO=0
STEP_TOTAL=9

say()   { printf '%s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_RST"; }
step()  {
    STEP_NO=$((STEP_NO + 1))
    printf '\n%s[%d/%d]%s %s%s%s\n' "$C_CYN" "$STEP_NO" "$STEP_TOTAL" "$C_RST" "$C_B" "$*" "$C_RST"
}
ok()    { printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$*"; }
bad()   { printf '  %s✘%s %s\n' "$C_RED" "$C_RST" "$*"; }
warn()  { printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*"; }
info()  { printf '  %s·%s %s\n' "$C_D" "$C_RST" "$*"; }
ind()   { sed 's/^/      /'; }

# 失败中止：$1=原因  $2=可操作建议（可多行）  $3=退出码
fail() {
    local reason="$1" advice="${2:-}" code="${3:-1}"
    printf '\n%s────────────────────────────────────────────────%s\n' "$C_RED" "$C_RST"
    bad "安装中止：$reason"
    if [ -n "$advice" ]; then
        printf '\n  %s你可以这样解决：%s\n' "$C_B" "$C_RST"
        printf '%s\n' "$advice" | sed 's/^/    /'
    fi
    printf '\n  %s完整日志：%s%s\n' "$C_D" "$LOG" "$C_RST"
    printf '%s────────────────────────────────────────────────%s\n' "$C_RED" "$C_RST"
    exit "$code"
}

# -------------------------------------------------------------------- 日志 --
TS=$(date +%Y%m%d-%H%M%S)
if [ "$(id -u)" -eq 0 ] && [ -d /var/log ] && [ -w /var/log ]; then
    LOG="/var/log/pve-nodeinfo-install-$TS.log"
else
    LOG="${TMPDIR:-/tmp}/pve-nodeinfo-install-$TS.log"
fi
# 屏幕输出同时落盘；进程替换不可用时静默降级，不阻断安装
exec > >(tee -a "$LOG") 2>&1 || LOG="(未记录)"

TMPD=""
cleanup() {
    [ -n "$TMPD" ] && [ -d "$TMPD" ] || return 0
    if [ "$KEEP" = "1" ]; then
        printf '\n%s临时文件保留在:%s %s\n' "$C_D" "$C_RST" "$TMPD"
    else
        rm -rf "$TMPD"
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------ 工具 ---
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    printf '\n%s需要 root 权限%s\n' "$C_RED" "$C_RST" >&2
    printf '  当前用户是 %s（uid=%s），本脚本要修改 PVE 的系统文件。\n\n' "$(id -un)" "$(id -u)" >&2
    printf '  正确做法（二选一）：\n' >&2
    printf '    1) 先切到 root：   su -\n' >&2
    printf '    2) 命令前加 sudo：\n' >&2
    printf '       curl -fsSL https://raw.githubusercontent.com/%s/main/install-online.sh | sudo bash\n\n' "$REPO" >&2
    exit 2
}

# 已安装版本：返回版本号字符串，未安装返回空
installed_version() {
    if [ -f "$CONF_DIR/VERSION" ]; then
        tr -d '[:space:]' <"$CONF_DIR/VERSION"
    elif grep -q 'pve-nodeinfo' "$NP" "$PJS" 2>/dev/null; then
        printf 'unknown'
    fi
}

api_json() {
    if have curl; then
        curl -fsSL --connect-timeout 10 --max-time 25 \
             -H 'Accept: application/vnd.github+json' \
             -H "User-Agent: pve-nodeinfo-installer/$SCRIPT_DATE" \
             "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null
    else
        wget -q -T 20 -O - --header="User-Agent: pve-nodeinfo-installer/$SCRIPT_DATE" \
             "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null
    fi
}

download() {  # $1=url  $2=目标文件
    if have curl; then
        curl -fL -sS --connect-timeout 10 --max-time 300 \
             --retry 2 --retry-delay 2 -o "$2" "$1"
    else
        wget -q -T 30 -t 3 -O "$2" "$1"
    fi
}

http_ok() {  # $1=url  连通返回 0
    if have curl; then
        curl -fsS -o /dev/null --connect-timeout 8 --max-time 12 "$1" >/dev/null 2>&1
    else
        wget -q -T 10 -O /dev/null "$1" >/dev/null 2>&1
    fi
}

# 取安装前最新的备份目录（没有则输出空）
latest_backup() {
    ls -1d /root/pve-nodeinfo-backup-* 2>/dev/null | sort | tail -1
}

# =============================================================== 开场 =====
head1 "pve-nodeinfo 一键安装"
printf '  %s目标：在 PVE 节点摘要面板增加 温度 / CPU频率 / 功耗 / 磁盘健康%s\n' "$C_D" "$C_RST"
printf '  %s日志：%s%s\n' "$C_D" "$LOG" "$C_RST"

need_root

# ======================================================= 1. 系统环境检查 ==
step "检查系统环境"

if ! have pveversion; then
    fail "这台机器不是 Proxmox VE" \
"本脚本只能在 PVE 主机上运行。

如果你是在自己的电脑（Windows / macOS / 普通 Linux）上跑的，请改成：
  1. 用 SSH 登录 PVE 主机：   ssh root@<PVE的IP>
  2. 在 PVE 主机上重新执行本命令

如果 PVE 主机本身丢了 pveversion 命令（极少见），执行：
  apt install --reinstall pve-manager" 2
fi

PVEVER=$(pveversion 2>/dev/null | awk -F'/' '{print $2}' | cut -d- -f1)
PVEMAJ=$(printf '%s' "$PVEVER" | cut -d. -f1)
ok "Proxmox VE $PVEVER"

if [ "$PVEMAJ" != "8" ] && [ "$PVEMAJ" != "9" ]; then
    fail "PVE 主版本 $PVEMAJ 不受支持（仅支持 8.x / 9.x）" \
"本插件靠匹配 PVE 源码里固定的代码片段（锚点）来定位插入点。
8.x / 9.x 之外的版本结构没有验证过，硬改很可能导致 Web 界面白屏。

请确认版本：  pveversion
如确实需要支持，请到项目主页提 issue：
  https://github.com/$REPO/issues" 2
elif [ "$PVEMAJ" = "8" ]; then
    warn "PVE 8.x 未经实测（开发与验证都在 9.x 完成），若安装失败请用 --uninstall 还原"
fi

if [ ! -d /run/systemd/system ]; then
    fail "systemd 未运行，无法安装定时采集服务" \
"本插件依赖 systemd timer 定时采集磁盘与功耗数据。

请确认：
  systemctl --version
  ps -p 1 -o comm=
如果 PID 1 不是 systemd，说明当前是容器（LXC / Docker），
插件必须装在 PVE 宿主机上，不能装在容器里。" 2
fi
ok "systemd 正常"

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    info "系统：${PRETTY_NAME:-未知}"
fi
info "内核：$(uname -r)"

AVAIL=$(df -Pk /var/tmp 2>/dev/null | awk 'NR==2{print $4}')
case "$AVAIL" in
    ''|*[!0-9]*) AVAIL=0 ;;
esac
if [ "$AVAIL" -lt 51200 ]; then
    fail "磁盘可用空间不足（/var/tmp 仅剩 $((AVAIL / 1024)) MB，需要 50 MB）" \
"清理一些空间后重试，例如：
  du -sh /var/log/* 2>/dev/null | sort -h | tail -5
  journalctl --vacuum-size=100M
  apt clean" 2
fi
info "可用空间：$((AVAIL / 1024)) MB"

if [ ! -f "$NP" ] || [ ! -f "$PJS" ]; then
    fail "找不到 PVE 界面文件，pve-manager 可能未正确安装" \
"缺失文件：
  $NP
  $PJS

修复：
  apt install --reinstall pve-manager proxmox-widget-toolkit
  systemctl restart pvedaemon pveproxy" 2
fi
ok "PVE 界面文件就位"

# 旧版社区脚本的残留会与本插件打架
if grep -q 'modbyshowtempfreq' "$NP" "$PJS" 2>/dev/null; then
    fail "检测到旧版社区脚本（PVE-manager-status）留下的补丁" \
"两者注入位置相同，同时存在会导致重复显示甚至白屏。

请先还原旧补丁，再运行本脚本：
  apt install --reinstall pve-manager proxmox-widget-toolkit
  systemctl restart pvedaemon pveproxy

还原后重新执行本脚本即可。" 2
fi

# ==================================================== 2. 卸载（提前分流）==
if [ "$DO_UNINSTALL" = "1" ]; then
    head1 "卸载 pve-nodeinfo"

    CUR_VER=$(installed_version)
    if [ -z "$CUR_VER" ]; then
        warn "本机没有检测到 pve-nodeinfo，无需卸载"
        info "如果面板上仍能看到扩展字段，执行："
        info "  apt install --reinstall pve-manager proxmox-widget-toolkit && systemctl restart pvedaemon pveproxy"
        exit 0
    fi
    info "已安装版本：$CUR_VER"

    # 必须先停定时器，否则删掉 /run/pve-nodeinfo 后下一轮采集又会建回来
    if systemctl disable --now "$TIMER" >/dev/null 2>&1; then
        ok "已停用 $TIMER"
    else
        info "定时器未启用，跳过"
    fi
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
    rm -f "$UNIT_DIR/timers.target.wants/$TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "已移除 systemd 单元"

    BK=$(latest_backup)
    if [ -n "$BK" ] && [ -f "$BK/pve-ui-files.tar.gz" ]; then
        tar xzf "$BK/pve-ui-files.tar.gz" -C / 2>/dev/null
        ok "已还原 PVE 界面文件"
        info "备份来源：$BK"
        if [ -f "$BK/before.sha256" ] && sha256sum -c "$BK/before.sha256" --quiet >/dev/null 2>&1; then
            ok "校验通过：与安装前完全一致"
        else
            warn "校验未通过，备份文件可能被改动过"
        fi
    else
        warn "找不到安装前的备份，界面文件无法自动还原"
        info "手动还原： apt install --reinstall pve-manager proxmox-widget-toolkit"
    fi

    rm -f "$HELPER" "$COLLECTOR"
    rm -rf "$CONF_DIR" "$RUNDIR"
    ok "已删除采集器与配置"

    systemctl restart pvedaemon pveproxy >/dev/null 2>&1
    sleep 2
    if pvesh get /nodes/localhost/status --output-format json 2>/dev/null | grep -q '"thermalstate"'; then
        warn "扩展字段仍存在，还原可能未生效"
        info "请执行： apt install --reinstall pve-manager proxmox-widget-toolkit"
    else
        ok "字段已移除，API 恢复原状"
    fi

    head1 "卸载完成"
    printf '  请在浏览器里按 %sShift+F5%s 强制刷新，节点摘要面板将恢复原样。\n\n' "$C_B" "$C_RST"
    exit 0
fi

# ========================================================= 2. 依赖准备 ===
step "检查并准备依赖"

MISSING_REQ=""
for c in python3 perl tar gzip sha256sum; do
    if have "$c"; then
        ok "$c 已就绪"
    else
        bad "$c 缺失"
        MISSING_REQ="$MISSING_REQ $c"
    fi
done

if have curl; then
    ok "curl 已就绪（用于下载）"
elif have wget; then
    ok "wget 已就绪（用于下载，无 curl）"
else
    bad "curl 和 wget 都没有"
    MISSING_REQ="$MISSING_REQ curl"
fi

if [ -n "$MISSING_REQ" ]; then
    fail "缺少必需依赖:$MISSING_REQ" \
"这些都是 PVE 自带的，缺失通常说明系统被精简过或软件源不可用。

尝试自动补齐：
  apt update
  apt install -y python3 perl tar gzip coreutils curl

如果 apt 报 401 / 404，说明订阅源不可用，先执行：
  sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
  apt update" 1
fi

PYV=$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo "0.0")
ok "python3 $PYV"

if [ -x "$SMARTCTL" ] || have smartctl; then
    ok "smartctl 已就绪（读取磁盘 SMART）"
else
    warn "smartctl 未安装 —— 磁盘行会显示「未知」，温度/频率/功耗不受影响"
    if have apt-get; then
        info "尝试自动安装 smartmontools（约 3 MB）..."
        APTLOG="${TMPDIR:-/tmp}/.pni-apt.$$.log"
        if apt-get install -y --no-install-recommends smartmontools >"$APTLOG" 2>&1; then
            ok "smartmontools 安装成功"
        elif apt-get update >"$APTLOG" 2>&1 &&
             apt-get install -y --no-install-recommends smartmontools >>"$APTLOG" 2>&1; then
            ok "smartmontools 安装成功（已先更新软件索引）"
        else
            warn "自动安装失败，本次跳过磁盘信息"
            info "手动安装： apt install -y smartmontools"
            info "错误摘录："
            tail -3 "$APTLOG" 2>/dev/null | ind
        fi
        rm -f "$APTLOG"
    else
        info "手动安装： apt install -y smartmontools"
    fi
fi

# ========================================================= 3. 网络连通 ===
step "检查网络连通性"

OFFLINE_PKG=0
if [ -n "$PKG_SRC" ]; then
    case "$PKG_SRC" in
        http://*|https://*) OFFLINE_PKG=0 ;;
        *)
            if [ -f "$PKG_SRC" ]; then
                OFFLINE_PKG=1
            else
                fail "本地包不存在：$PKG_SRC" \
"检查路径是否写对：
  ls -l $PKG_SRC

想用网址的话，请写完整地址（以 http:// 或 https:// 开头）。" 1
            fi
            ;;
    esac
fi

if [ "$OFFLINE_PKG" = "1" ]; then
    info "使用本地包，跳过网络检查"
else
    NET_OK=0
    for u in https://api.github.com https://github.com https://objects.githubusercontent.com; do
        if http_ok "$u"; then
            ok "可访问 $u"
            NET_OK=1
            break
        else
            bad "无法访问 $u"
        fi
    done

    if [ "$NET_OK" = "0" ]; then
        fail "主机无法访问 GitHub，下载不了发布包" \
"本插件需要从 GitHub 下载安装包（约 38 KB）。按顺序排查：

1) 先确认主机能不能上网：
     ping -c 2 223.5.5.5
     cat /etc/resolv.conf
   ping 通但域名解析不了 = DNS 问题：
     echo 'nameserver 223.5.5.5' > /etc/resolv.conf

2) 如果主机走代理上网（例如 iStoreOS / Clash），给本次安装临时指定代理：
     export https_proxy=http://<代理IP>:<端口>
     export http_proxy=http://<代理IP>:<端口>
   然后重新执行本脚本。

3) 实在不行就用离线安装：
   - 在能上网的电脑下载
       https://github.com/$REPO/releases/latest
     里的 pve-nodeinfo-*.tar.gz
   - 上传到 PVE（scp 或 Web 界面上传）
   - 执行
       bash install-online.sh --pkg /path/to/pve-nodeinfo-1.2.0.tar.gz" 3
    fi
fi

# ======================================================== 4. 已装状态 ===
step "检查是否已安装"

CUR_VER=$(installed_version)
TARGET_VER=""
PKG_URL=""
PKG_SHA=""

if [ -n "$CUR_VER" ]; then
    if [ "$CUR_VER" = "unknown" ]; then
        warn "检测到 pve-nodeinfo 的补丁标记，但读不到版本号（可能是较早的版本）"
    else
        warn "主机已安装 pve-nodeinfo $CUR_VER"
    fi
else
    ok "未安装过，本次为全新安装"
fi

# ========================================================== 5. 定版本 ===
step "确定要安装的版本"

if [ -n "$WANT_VERSION" ]; then
    TARGET_VER="$WANT_VERSION"
    ok "使用指定版本 $TARGET_VER"
elif [ -n "$PKG_SRC" ]; then
    TARGET_VER=$(basename "$PKG_SRC" | sed -n 's/^pve-nodeinfo-\([0-9][0-9.]*\)\.tar\.gz$/\1/p')
    [ -z "$TARGET_VER" ] && TARGET_VER="$DEFAULT_VERSION"
    ok "从包文件名识别出版本 $TARGET_VER"
else
    info "查询 GitHub 最新版本 ..."
    PARSED=$(api_json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
tag = (d.get("tag_name") or "").lstrip("v")
for a in d.get("assets") or []:
    n = a.get("name") or ""
    if n.startswith("pve-nodeinfo-") and n.endswith(".tar.gz"):
        print(tag, a.get("browser_download_url") or "", a.get("digest") or "", sep="\t")
        break
' 2>/dev/null || true)

    if [ -n "$PARSED" ]; then
        TARGET_VER=$(printf '%s' "$PARSED" | cut -f1)
        PKG_URL=$(printf '%s' "$PARSED" | cut -f2)
        PKG_SHA=$(printf '%s' "$PARSED" | cut -f3 | sed 's/^sha256://')
        ok "GitHub 最新版本：$TARGET_VER"
    else
        warn "无法从 GitHub 读取版本信息（可能 API 限流），回退到内置版本"
        TARGET_VER="$DEFAULT_VERSION"
    fi
fi

if [ -z "$TARGET_VER" ]; then
    TARGET_VER="$DEFAULT_VERSION"
fi

# API 没给 digest 时用内置校验表兜底
if [ -z "$PKG_SHA" ]; then
    case "$TARGET_VER" in
        *[!0-9.]*|"") ;;
        *) if [ -n "${KNOWN_SHA[$TARGET_VER]:-}" ]; then
               PKG_SHA="${KNOWN_SHA[$TARGET_VER]}"
               info "使用内置校验值"
           fi ;;
    esac
fi

# ------------------------------------------------------------ 体检出口 --
if [ "$DOCTOR" = "1" ]; then
    head1 "体检完成，环境满足安装条件"
    printf '  将安装版本：%s\n' "$TARGET_VER"
    printf '  预计耗时：  10 ~ 30 秒\n'
    printf '  副作用：    修改 2 个 PVE 界面文件（自动备份）、新增 1 个定时器\n\n'
    printf '  执行安装：  bash install-online.sh\n'
    printf '  仅预演：    bash install-online.sh --dry-run\n\n'
    exit 0
fi

# ------------------------------------------------------- 同版本则跳过 ---
if [ -n "$CUR_VER" ] && [ "$CUR_VER" = "$TARGET_VER" ] && [ "$FORCE" = "0" ] && [ "$DRY" = "0" ]; then
    head1 "已经是最新版本，无需重复安装"
    printf '  主机上装的是 %s，目标版本也是 %s。\n' "$CUR_VER" "$TARGET_VER"
    printf '  重复安装不会带来任何变化，已自动跳过（没有修改任何文件）。\n\n'
    printf '  强制重装：  bash install-online.sh --force\n'
    printf '  卸载：      bash install-online.sh --uninstall\n'

    step "验证当前安装"
    if systemctl is-active --quiet "$TIMER"; then
        ok "$TIMER 运行中"
    else
        warn "$TIMER 未运行（缓存会停止刷新）"
        info "修复： systemctl enable --now $TIMER"
    fi
    if [ -s "$RUNDIR/power.json" ]; then
        ok "功耗缓存：$(tr -d '\n' <"$RUNDIR/power.json" | cut -c1-70)"
    else
        warn "功耗缓存缺失，10 秒内会自动重建"
    fi
    if [ -s "$RUNDIR/sd0.json" ]; then
        ok "磁盘缓存：$(stat -c%s "$RUNDIR/sd0.json") 字节"
    else
        warn "磁盘缓存缺失（若本机没有 SATA/NVMe 磁盘，属正常）"
    fi
    if pvesh get /nodes/localhost/status --output-format json 2>/dev/null | grep -q '"powerState"'; then
        ok "API 已返回扩展字段"
    else
        warn "API 未返回扩展字段，重启服务可修复： systemctl restart pvedaemon pveproxy"
    fi
    printf '\n  %s别忘了在浏览器里按 Shift+F5 强制刷新。%s\n\n' "$C_D" "$C_RST"
    exit 0
fi

# dry-run 无法在已安装状态下进行（install.sh 会拒绝重复注入）
if [ "$DRY" = "1" ] && [ -n "$CUR_VER" ]; then
    head1 "预演无法执行"
    printf '  主机上已安装 pve-nodeinfo %s，预演会产生误判（install.sh 会拒绝重复注入）。\n\n' "$CUR_VER"
    printf '  想真正预演，请先卸载：\n'
    printf '    bash install-online.sh --uninstall\n'
    printf '    bash install-online.sh --dry-run\n\n'
    exit 0
fi

if [ -n "$CUR_VER" ] && [ "$CUR_VER" != "$TARGET_VER" ]; then
    head1 "将执行版本变更：$CUR_VER → $TARGET_VER"
    printf '  已存在旧版本，会先卸载（还原 PVE 界面文件）再安装新版本。\n'
    printf '  安装前的原始文件会备份到 /root/pve-nodeinfo-backup-<时间戳>/。\n'
    printf '  %s下载与校验都在卸载之前完成，中途失败不会影响你现在能用的版本。%s\n' "$C_D" "$C_RST"
fi

# ============================================================ 6. 下载 ====
step "获取发布包"

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/pve-ni.XXXXXX") || fail "无法创建临时目录" \
"检查 /tmp 是否可写：
  ls -ld /tmp
  df -h /tmp" 1

PKGFILE="$TMPD/pve-nodeinfo-$TARGET_VER.tar.gz"

if [ "$OFFLINE_PKG" = "1" ]; then
    cp -f "$PKG_SRC" "$PKGFILE" || fail "复制本地包失败：$PKG_SRC" \
"检查文件是否可读、磁盘是否写满：
  ls -l $PKG_SRC
  df -h /tmp" 1
    ok "已使用本地包：$PKG_SRC"
fi

if [ ! -s "$PKGFILE" ]; then
    if [ -n "$PKG_SRC" ] && [ "$OFFLINE_PKG" = "0" ]; then
        PKG_URL="$PKG_SRC"
    fi
    if [ -z "$PKG_URL" ]; then
        PKG_URL="https://github.com/$REPO/releases/download/v$TARGET_VER/pve-nodeinfo-$TARGET_VER.tar.gz"
    fi

    URLS=("$PKG_URL")
    if [ "$MIRROR" = "1" ]; then
        URLS+=("https://ghfast.top/$PKG_URL" "https://gh-proxy.com/$PKG_URL" "https://ghproxy.net/$PKG_URL")
        info "已启用加速镜像（内容仍需通过 SHA256 校验，镜像无法篡改）"
    fi

    DLED=0
    LAST_ERR=""
    for u in "${URLS[@]}"; do
        info "下载 $u"
        rm -f "$PKGFILE"
        LAST_ERR=$(download "$u" "$PKGFILE" 2>&1)
        if [ -s "$PKGFILE" ]; then
            ok "下载完成（$(du -k "$PKGFILE" | cut -f1) KB）"
            DLED=1
            break
        fi
        bad "失败：${LAST_ERR:-无输出}"
    done

    if [ "$DLED" = "0" ]; then
        fail "发布包下载失败（已尝试 ${#URLS[@]} 个地址）" \
"最后一次的错误信息：
${LAST_ERR:-（无）}

常见原因与对策：

· Could not resolve host —— DNS 解析失败
    echo 'nameserver 223.5.5.5' > /etc/resolv.conf

· Connection timed out / Failed to connect —— 出网被拦
    给本次安装指定代理后重试：
      export https_proxy=http://<代理IP>:<端口>
      bash install-online.sh

· 404 Not Found —— 该版本不存在
    查看可用版本： https://github.com/$REPO/releases
    或指定版本：   bash install-online.sh --version 1.2.0

· 下载慢或反复中断 —— 换加速镜像：
    bash install-online.sh --mirror" 3
    fi
fi

# ============================================================ 7. 校验 ====
step "校验发布包完整性"

if [ -n "$PKG_SHA" ]; then
    ACTUAL=$(sha256sum "$PKGFILE" | cut -d' ' -f1)
    if [ "$ACTUAL" = "$PKG_SHA" ]; then
        ok "SHA256 校验通过"
        info "$ACTUAL"
    else
        fail "发布包校验失败，文件可能在传输中损坏或被篡改" \
"期望值：$PKG_SHA
实际值：$ACTUAL

请立即停止，不要继续安装。重试下载：
  bash install-online.sh --force

若反复失败，可能是网络中间设备改写了内容，
换网络，或用 --pkg 指定已在别处验证过的本地包。" 4
    fi
else
    warn "没有可用的校验值（API 未返回 digest，且该版本不在内置表中）"
    info "已跳过完整性校验，请自行确认包来源可信"
fi

tar tzf "$PKGFILE" >/dev/null 2>&1 || fail "发布包不是有效的 tar.gz 文件" \
"文件头校验失败，通常是下载不完整。

重试：
  bash install-online.sh --force

如果仍失败，检查磁盘是否写满： df -h /tmp" 4

tar xzf "$PKGFILE" -C "$TMPD" || fail "解压发布包失败" \
"检查磁盘空间： df -h /tmp
保留临时文件便于排查： bash install-online.sh --keep" 4

TOPDIR=$(tar tzf "$PKGFILE" | head -1 | cut -d/ -f1)
SRC_DIR="$TMPD/$TOPDIR"
[ -f "$SRC_DIR/install.sh" ] || SRC_DIR="$TMPD/pve-nodeinfo-$TARGET_VER"

if [ ! -f "$SRC_DIR/install.sh" ]; then
    fail "发布包结构异常，找不到 install.sh" \
"包内顶层目录应为 pve-nodeinfo-$TARGET_VER/。
请用 --keep 保留临时文件后反馈到：
  https://github.com/$REPO/issues" 4
fi
ok "解压完成：$TOPDIR"

for f in scripts/patch_pve_nodes.py scripts/pve-hwinfo.sh scripts/pve-nodeinfo-collect \
         systemd/$SERVICE systemd/$TIMER uninstall.sh VERSION; do
    [ -f "$SRC_DIR/$f" ] || fail "发布包不完整，缺少 $f" \
"下载的包可能被截断。删除后重新下载：
  bash install-online.sh --force" 4
done
ok "文件清单完整"

# ============================================================ 8. 安装 ====
step "执行安装"

NEED_UNINSTALL=0
if [ -n "$CUR_VER" ]; then
    if [ "$CUR_VER" != "$TARGET_VER" ] || [ "$FORCE" = "1" ]; then
        NEED_UNINSTALL=1
    fi
fi

if [ "$NEED_UNINSTALL" = "1" ]; then
    info "先卸载旧版本 ..."
    UNLOG="${TMPDIR:-/tmp}/.pni-uninst.$$.log"
    # 优先用包内同名版本的卸载脚本，保证与安装逻辑对偶
    if bash "$SRC_DIR/uninstall.sh" >"$UNLOG" 2>&1; then
        ok "旧版本已卸载"
    else
        # 备份丢失等情况不算致命，但要如实告知
        warn "卸载过程有报错，继续安装（详情见下）"
        tail -5 "$UNLOG" | ind
    fi
    rm -f "$UNLOG"
    CUR_VER=""
fi

if [ "$DRY" = "1" ]; then
    bash "$SRC_DIR/install.sh" --dry-run
else
    bash "$SRC_DIR/install.sh"
fi
INSTALL_RC=$?

if [ "$INSTALL_RC" -ne 0 ]; then
    if [ "$DRY" = "1" ]; then
        fail "预演失败（退出码 $INSTALL_RC）" \
"预演不写任何文件，失败说明环境或 PVE 版本不匹配。
请把上面的错误信息连同日志一起反馈：
  https://github.com/$REPO/issues" 5
    fi
    printf '\n'
    fail "安装脚本执行失败（退出码 $INSTALL_RC），已自动回滚" \
"install.sh 内置回滚：失败时会把 Nodes.pm 与 pvemanagerlib.js
还原到安装前的备份，所以不会把 PVE 界面弄坏。

按错误信息对照处理：

· 锚点不匹配 / 找不到插入点
    PVE 版本与插件验证过的版本不同。确认： pveversion
    反馈时请附上该命令输出。

· www-data 无法读取缓存
    检查目录： ls -ld $RUNDIR
    手工重建： $COLLECTOR

· 采集器执行失败
    查看日志： journalctl -u $SERVICE -n 50 --no-pager

· 其他
    完整日志： $LOG" 5
fi

if [ "$DRY" = "1" ]; then
    head1 "预演完成"
    printf '  以上为将要执行的操作，%s没有写入任何文件%s。\n' "$C_B" "$C_RST"
    printf '  确认无误后正式安装：  bash install-online.sh\n\n'
    exit 0
fi

# ============================================================ 9. 验证 ====
step "验证安装结果"

FAILS=0
chk() {
    if eval "$2" >/dev/null 2>&1; then
        ok "$1"
    else
        bad "$1"
        FAILS=$((FAILS + 1))
    fi
}

chk "定时器 $TIMER 运行中"     "systemctl is-active --quiet $TIMER"
chk "采集服务单元已安装"       "[ -f $UNIT_DIR/$SERVICE ]"
chk "功耗缓存可读"             "[ -s $RUNDIR/power.json ]"
chk "磁盘缓存可读"             "[ -s $RUNDIR/sd0.json ]"
chk "www-data 可读缓存"        "runuser -u www-data -- test -r $RUNDIR/power.json"
chk "pvedaemon 运行中"         "systemctl is-active --quiet pvedaemon"
chk "pveproxy 运行中"          "systemctl is-active --quiet pveproxy"
chk "API 返回扩展字段"         "pvesh get /nodes/localhost/status --output-format json 2>/dev/null | grep -q '\"powerState\"'"
chk "补丁标记已写入"           "grep -q pve-nodeinfo $NP"

PW=$(cat "$RUNDIR/power.json" 2>/dev/null || true)
PKGW=$(printf '%s' "$PW" | sed -n 's/.*"pkg_w": *\([0-9.]*\).*/\1/p' | head -1)
[ -n "$PKGW" ] && info "当前 CPU 封装功耗：${PKGW} W"

# ============================================================ 收尾 ====
if [ "$FAILS" -eq 0 ]; then
    head1 "安装成功"
    printf '  %s全部 9 项验证通过。%s\n' "$C_GRN" "$C_RST"
else
    head1 "安装完成，但有 $FAILS 项验证未通过"
    printf '  %s补丁已生效，请按下面的提示检查这几项。%s\n' "$C_YEL" "$C_RST"
fi

cat <<EOF

  已安装版本：$TARGET_VER
  原始文件备份：/root/pve-nodeinfo-backup-<时间戳>/

  ${C_B}接下来做两件事：${C_RST}
    1. 浏览器打开  https://<PVE地址>:8006
    2. 按 ${C_B}Shift + F5${C_RST} 强制刷新（必须，否则看到的是浏览器旧缓存）

  节点「摘要」面板会出现 4 行新内容：
    温度(°C)      主板 / CPU 封装 / 各核心
    CPU频率(GHz)  各核心实时频率 / 最大最小 / 调速器
    功耗(W)       CPU 封装功耗（主板 psys 正常时额外显示整机功耗）
    固态硬盘0     型号 / 温度 / 通电次数 / SMART 健康

  ${C_B}常用命令：${C_RST}
    systemctl status $TIMER        查看定时器
    systemctl list-timers $TIMER   查看下次采集时间
    $COLLECTOR                     手工刷新一次缓存

  ${C_B}卸载（PVE 升级前务必执行）：${C_RST}
    bash install-online.sh --uninstall

EOF

[ "$FAILS" -eq 0 ] || exit 1
exit 0
