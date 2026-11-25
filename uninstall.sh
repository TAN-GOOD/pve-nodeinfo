#!/usr/bin/env bash
# pve-nodeinfo 卸载脚本
# 用法: sudo ./uninstall.sh [备份目录]
set -euo pipefail

NP=/usr/share/perl5/PVE/API2/Nodes.pm
PJS=/usr/share/pve-manager/js/pvemanagerlib.js
HELPER=/usr/local/bin/pve-hwinfo.sh
COLLECTOR=/usr/local/bin/pve-nodeinfo-collect
CONF_DIR=/etc/pve-nodeinfo
RUNDIR=/run/pve-nodeinfo
UNIT_DIR=/etc/systemd/system
SERVICE=pve-nodeinfo-collect.service
TIMER=pve-nodeinfo-collect.timer

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

step "环境检查"
[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo ./uninstall.sh）"
if [ -f "$CONF_DIR/VERSION" ]; then
    say "主机上的已安装版本: $(cat "$CONF_DIR/VERSION")"
fi

# ---------- 定位备份 ----------
BK="${1:-}"
if [ -z "$BK" ]; then
    BK=$(ls -1d /root/pve-nodeinfo-backup-* 2>/dev/null | sort | tail -1 || true)
fi

if [ -z "$BK" ] || [ ! -f "$BK/pve-ui-files.tar.gz" ]; then
    say "未找到可用的备份包：$NP / $PJS 无法自动还原。"
    say "可选方案（会联网下载官方包，需主机能访问软件源）："
    say "  apt install --reinstall pve-manager proxmox-widget-toolkit"
    say "  systemctl restart pvedaemon pveproxy"
    say ""
    say "以下清理步骤仍会执行（定时器、采集器、配置文件）："
    BK=""
else
    say "使用备份: $BK"
fi

# ---------- 先停定时器 ----------
# 必须最先做：否则删掉 /run/pve-nodeinfo 后，下一轮采集又会把它建回来
step "停用定时采集"
if systemctl list-unit-files "$TIMER" >/dev/null 2>&1 &&
   systemctl is-enabled "$TIMER" >/dev/null 2>&1; then
    systemctl disable --now "$TIMER" || true
    say "已停用 $TIMER"
else
    say "定时器未启用，跳过"
fi
systemctl stop "$SERVICE" >/dev/null 2>&1 || true
rm -f "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
rm -f "$UNIT_DIR/timers.target.wants/$TIMER"
systemctl daemon-reload
say "已移除 systemd 单元"

# ---------- 还原 PVE 界面文件 ----------
if [ -n "$BK" ]; then
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
fi

# ---------- 移除采集器与配置 ----------
step "移除采集器与配置"
for f in "$HELPER" "$COLLECTOR"; do
    if [ -f "$f" ]; then
        rm -f "$f"
        say "已删除 $f"
    else
        say "$f 不存在，跳过"
    fi
done
if [ -d "$CONF_DIR" ]; then
    rm -rf "$CONF_DIR"
    say "已删除 $CONF_DIR"
fi
if [ -d "$RUNDIR" ]; then
    rm -rf "$RUNDIR"
    say "已删除 $RUNDIR"
fi

# ---------- 确认标记已清除 ----------
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
        say "警告：thermalstate 字段仍存在，还原可能未生效"
    else
        say "字段已移除，API 恢复原始状态"
    fi
fi

cat <<EOF

卸载完成。

请在浏览器中按 Shift+F5 强制刷新，节点摘要面板将恢复原样。
EOF

if [ -n "$BK" ]; then
    cat <<EOF
备份目录保留在 $BK，确认无问题后可手动删除：
  rm -rf $BK
EOF
fi
