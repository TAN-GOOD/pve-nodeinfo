#!/usr/bin/env bash
# pve-nodeinfo 卸载脚本
# 用法: sudo ./uninstall.sh [备份目录]
set -euo pipefail

NP=/usr/share/perl5/PVE/API2/Nodes.pm
PJS=/usr/share/pve-manager/js/pvemanagerlib.js
HELPER=/usr/local/bin/pve-hwinfo.sh

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

step "环境检查"
[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo ./uninstall.sh）"

# ---------- 定位备份 ----------
BK="${1:-}"
if [ -z "$BK" ]; then
    BK=$(ls -1d /root/pve-nodeinfo-backup-* 2>/dev/null | sort | tail -1 || true)
fi

if [ -z "$BK" ] || [ ! -f "$BK/pve-ui-files.tar.gz" ]; then
    say "未找到可用的备份包。"
    say "可选方案（会联网下载官方包，需主机能访问软件源）："
    say "  apt install --reinstall pve-manager proxmox-widget-toolkit"
    say "  systemctl restart pvedaemon pveproxy"
    die "中止"
fi
say "使用备份: $BK"

# ---------- 还原 ----------
step "还原 PVE 界面文件"
tar xzf "$BK/pve-ui-files.tar.gz" -C /
say "已还原 $NP"
say "已还原 $PJS"

if [ -f "$BK/before.sha256" ]; then
    if sha256sum -c "$BK/before.sha256" --quiet 2>/dev/null; then
        say "校验通过：与安装前完全一致"
    else
        say "警告：校验不一致，备份文件可能已被改动"
    fi
fi

# ---------- 移除采集脚本 ----------
step "移除采集脚本"
if [ -f "$HELPER" ]; then
    rm -f "$HELPER"
    say "已删除 $HELPER"
else
    say "采集脚本不存在，跳过"
fi

# ---------- 清理标记检查 ----------
step "确认补丁标记已清除"
if grep -q 'pve-nodeinfo' "$NP" "$PJS" 2>/dev/null; then
    say "警告：仍残留 pve-nodeinfo 标记，请检查备份是否正确"
else
    say "标记已清除"
fi

# ---------- 重启 ----------
step "重启 pvedaemon / pveproxy"
systemctl restart pvedaemon pveproxy
sleep 2
systemctl is-active pvedaemon pveproxy 2>/dev/null | sed 's/^/    /' || true

# ---------- 验证 ----------
step "验证 API"
if command -v pvesh >/dev/null 2>&1; then
    if pvesh get /nodes/localhost/status --output-format json 2>/dev/null | grep -q '"thermalstate"'; then
        say "警告：temperature 字段仍存在，还原可能未生效"
    else
        say "字段已移除，API 恢复原始状态"
    fi
fi

cat <<EOF

卸载完成。

请在浏览器中按 Shift+F5 强制刷新，节点摘要面板将恢复原样。
备份目录保留在 $BK，确认无问题后可手动删除：
  rm -rf $BK
EOF
