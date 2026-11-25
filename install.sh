#!/usr/bin/env bash
# pve-nodeinfo 安装脚本
# 用法: sudo ./install.sh [--dry-run]
set -euo pipefail

VERSION="1.0.0"
NP=/usr/share/perl5/PVE/API2/Nodes.pm
PJS=/usr/share/pve-manager/js/pvemanagerlib.js
HELPER=/usr/local/bin/pve-hwinfo.sh
SM=/usr/sbin/smartctl

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=/root/pve-nodeinfo-backup-$TS

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

# ---------- 前置检查 ----------
step "环境检查"
[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo ./install.sh）"
command -v pveversion >/dev/null 2>&1 || die "未检测到 pveversion，这不是 Proxmox VE 主机"
command -v python3 >/dev/null 2>&1 || die "需要 python3（PVE 自带，缺失请先安装）"
[ -f "$NP" ] || die "找不到 $NP"
[ -f "$PJS" ] || die "找不到 $PJS"
[ -f "$SRC_DIR/scripts/patch_pve_nodes.py" ] || die "发布包不完整：缺少 scripts/patch_pve_nodes.py"
[ -f "$SRC_DIR/scripts/pve-hwinfo.sh" ] || die "发布包不完整：缺少 scripts/pve-hwinfo.sh"

PVEVER=$(pveversion | awk -F'/' '{print $2}')
say "pve-nodeinfo $VERSION"
say "PVE 版本: $PVEVER"
say "python3:  $(python3 --version 2>&1)"

# ---------- 已安装检查 ----------
if grep -q 'pve-nodeinfo' "$NP" "$PJS" 2>/dev/null; then
    die "检测到已安装 pve-nodeinfo。如需重装，请先执行 ./uninstall.sh"
fi
if grep -q 'modbyshowtempfreq' "$NP" "$PJS" 2>/dev/null; then
    die "检测到旧版社区脚本留下的补丁。请先还原，再安装本版本"
fi

# ---------- 磁盘预检 ----------
step "磁盘检测"
if [ -x "$SM" ]; then
    say "smartctl: 已安装 ($("$SM" --version 2>/dev/null | head -1))"
else
    say "警告: 未找到 $SM，磁盘信息将无法显示（不影响温度与频率）"
fi

# ---------- 备份 ----------
step "备份原始文件"
if [ "$DRY" -eq 1 ]; then
    say "[dry-run] 将备份到 $BACKUP_DIR"
else
    mkdir -p "$BACKUP_DIR"
    tar czf "$BACKUP_DIR/pve-ui-files.tar.gz" "$NP" "$PJS" 2>/dev/null
    sha256sum "$NP" "$PJS" > "$BACKUP_DIR/before.sha256"
    pveversion > "$BACKUP_DIR/pveversion.txt" 2>/dev/null || true
    dpkg -l pve-manager proxmox-widget-toolkit 2>/dev/null | tail -3 > "$BACKUP_DIR/packages.txt" || true
    say "已备份到 $BACKUP_DIR"
    say "回滚命令: ./uninstall.sh"
fi

# ---------- 部署采集脚本 ----------
step "部署采集脚本"
if [ "$DRY" -eq 1 ]; then
    say "[dry-run] 将安装 $HELPER"
else
    install -o root -g root -m 0755 "$SRC_DIR/scripts/pve-hwinfo.sh" "$HELPER"
    say "已安装 $HELPER"
    say "采集测试:"
    "$HELPER" thermal 2>&1 | sed 's/^/    /' || true
fi

# ---------- 打补丁 ----------
step "修改 PVE 界面文件"
if [ "$DRY" -eq 1 ]; then
    python3 "$SRC_DIR/scripts/patch_pve_nodes.py" --dry-run
    say ""
    say "[dry-run] 未做任何修改"
    exit 0
fi

if ! python3 "$SRC_DIR/scripts/patch_pve_nodes.py"; then
    say "打补丁失败，开始自动回滚"
    tar xzf "$BACKUP_DIR/pve-ui-files.tar.gz" -C / 2>/dev/null || true
    rm -f "$HELPER"
    systemctl restart pvedaemon pveproxy 2>/dev/null || true
    die "已回滚到安装前状态"
fi

# ---------- 语法自检 ----------
step "语法自检"
if perl -I/usr/share/perl5 -c "$NP" >/dev/null 2>&1; then
    say "Nodes.pm: 语法通过"
else
    say "Nodes.pm: 语法错误，开始自动回滚"
    tar xzf "$BACKUP_DIR/pve-ui-files.tar.gz" -C / 2>/dev/null || true
    rm -f "$HELPER"
    systemctl restart pvedaemon pveproxy 2>/dev/null || true
    die "已回滚到安装前状态"
fi

# ---------- 重启服务 ----------
step "重启 pvedaemon / pveproxy"
systemctl restart pvedaemon pveproxy
sleep 2
systemctl is-active pvedaemon pveproxy 2>/dev/null | sed 's/^/    /' || true

# ---------- 验证 ----------
step "验证 API 输出"
if command -v pvesh >/dev/null 2>&1; then
    if pvesh get /nodes/localhost/status --output-format json 2>/dev/null | grep -q '"thermalstate"'; then
        say "温度字段: 正常"
    else
        say "温度字段: 缺失（请查看 journalctl -u pvedaemon）"
    fi
    if pvesh get /nodes/localhost/status --output-format json 2>/dev/null | grep -q '"cpuFreq"'; then
        say "频率字段: 正常"
    else
        say "频率字段: 缺失"
    fi
fi

cat <<EOF

安装完成。

下一步：
  1. 浏览器打开 PVE 管理界面 https://<你的PVE地址>:8006
  2. 按 Shift+F5 强制刷新缓存（必须，否则看不到新内容）
  3. 在节点「摘要」面板查看 温度 / CPU频率 / 磁盘 三行信息

卸载： ./uninstall.sh
备份： $BACKUP_DIR
EOF
