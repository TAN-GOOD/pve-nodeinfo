#!/usr/bin/env bash
# pve-nodeinfo 安装脚本
# 用法: sudo ./install.sh [--dry-run]
set -euo pipefail

VERSION="1.2.0"
NP=/usr/share/perl5/PVE/API2/Nodes.pm
PJS=/usr/share/pve-manager/js/pvemanagerlib.js
HELPER=/usr/local/bin/pve-hwinfo.sh
COLLECTOR=/usr/local/bin/pve-nodeinfo-collect
CONF_DIR=/etc/pve-nodeinfo
RUNDIR=/run/pve-nodeinfo
UNIT_DIR=/etc/systemd/system
SERVICE=pve-nodeinfo-collect.service
TIMER=pve-nodeinfo-collect.timer
SM=/usr/sbin/smartctl

SRC_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TS=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=/root/pve-nodeinfo-backup-$TS

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die()  { printf '错误: %s\n' "$*" >&2; exit 1; }

rollback() {
    say "正在回滚到安装前状态 ..."
    systemctl disable --now "$TIMER" >/dev/null 2>&1 || true
    systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$SERVICE" "$UNIT_DIR/$TIMER"
    rm -f "$UNIT_DIR/timers.target.wants/$TIMER"
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ -f "$BACKUP_DIR/pve-ui-files.tar.gz" ]; then
        tar xzf "$BACKUP_DIR/pve-ui-files.tar.gz" -C / 2>/dev/null || true
    fi
    rm -f "$HELPER" "$COLLECTOR"
    rm -rf "$CONF_DIR" "$RUNDIR"
    systemctl restart pvedaemon pveproxy >/dev/null 2>&1 || true
    say "回滚完成"
}

# ---------- 前置检查 ----------
step "环境检查"
[ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo ./install.sh）"
command -v pveversion >/dev/null 2>&1 || die "未检测到 pveversion，这不是 Proxmox VE 主机"
command -v python3 >/dev/null 2>&1 || die "需要 python3（PVE 自带，缺失请先安装）"
command -v systemctl >/dev/null 2>&1 || die "需要 systemd"
[ -f "$NP" ] || die "找不到 $NP"
[ -f "$PJS" ] || die "找不到 $PJS"
for f in scripts/patch_pve_nodes.py scripts/pve-hwinfo.sh scripts/pve-nodeinfo-collect \
         systemd/$SERVICE systemd/$TIMER; do
    [ -f "$SRC_DIR/$f" ] || die "发布包不完整：缺少 $f"
done

PVEVER=$(pveversion | awk -F'/' '{print $2}')
say "pve-nodeinfo $VERSION"
say "PVE 版本: $PVEVER"
say "python3:  $(python3 --version 2>&1)"

# ---------- 已安装检查 ----------
if grep -q 'pve-nodeinfo' "$NP" "$PJS" 2>/dev/null; then
    die "检测到已安装 pve-nodeinfo。升级或重装请先执行 ./uninstall.sh"
fi
if grep -q 'modbyshowtempfreq' "$NP" "$PJS" 2>/dev/null; then
    die "检测到旧版社区脚本留下的补丁。请先还原，再安装本版本"
fi

# ---------- 磁盘预检 ----------
step "磁盘检测"
if [ -x "$SM" ]; then
    say "smartctl: 已安装 ($("$SM" --version 2>/dev/null | head -1))"
else
    say "警告: 未找到 $SM，磁盘信息将显示为「未知」（温度与频率不受影响）"
    say "      安装方法: apt install smartmontools"
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
fi

# ---------- 部署采集脚本 ----------
step "部署采集脚本"
if [ "$DRY" -eq 1 ]; then
    say "[dry-run] 将安装 $HELPER（温度/频率，只读 sysfs）"
    say "[dry-run] 将安装 $COLLECTOR（磁盘 SMART + CPU 封装功耗，root 预采集）"
else
    install -o root -g root -m 0755 "$SRC_DIR/scripts/pve-hwinfo.sh" "$HELPER"
    install -o root -g root -m 0755 "$SRC_DIR/scripts/pve-nodeinfo-collect" "$COLLECTOR"
    say "已安装 $HELPER"
    say "已安装 $COLLECTOR"
    say "采集测试:"
    "$HELPER" thermal 2>&1 | sed 's/^/    /' || true
fi

# ---------- 打补丁 ----------
step "修改 PVE 界面文件"
if [ "$DRY" -eq 1 ]; then
    python3 "$SRC_DIR/scripts/patch_pve_nodes.py" --dry-run
    say ""
    say "[dry-run] 将安装 systemd 单元 $SERVICE / $TIMER"
    say "[dry-run] 未做任何修改"
    exit 0
fi

if ! python3 "$SRC_DIR/scripts/patch_pve_nodes.py"; then
    rollback
    die "打补丁失败，已回滚"
fi

# ---------- 语法自检 ----------
step "语法自检"
if perl -I/usr/share/perl5 -c "$NP" >/dev/null 2>&1; then
    say "Nodes.pm: 语法通过"
else
    perl -I/usr/share/perl5 -c "$NP" 2>&1 | sed 's/^/    /' | head -5 || true
    rollback
    die "Nodes.pm 语法错误，已回滚"
fi

# ---------- 安装 systemd 单元 ----------
step "安装 systemd 定时采集"
install -o root -g root -m 0644 "$SRC_DIR/systemd/$SERVICE" "$UNIT_DIR/$SERVICE"
install -o root -g root -m 0644 "$SRC_DIR/systemd/$TIMER" "$UNIT_DIR/$TIMER"
systemctl daemon-reload

# 先手工跑，确保缓存就绪后才重启 pveproxy。
# 必须跑两次：RAPL 的 energy_uj 是累计值，要两次采样差分才能算出瓦数，
# 第一次只建立基线（warmup），第二次才写入有效功率。
if ! systemctl start "$SERVICE"; then
    systemctl status "$SERVICE" --no-pager -l 2>&1 | tail -8 | sed 's/^/    /' || true
    rollback
    die "采集器执行失败，已回滚"
fi
sleep 2
systemctl start "$SERVICE" >/dev/null 2>&1 || true

if ! systemctl enable --now "$TIMER" >/dev/null 2>&1; then
    rollback
    die "定时器启用失败，已回滚"
fi
say "已启用 $TIMER（每 5 秒采集一次）"

# ---------- 记录安装版本 ----------
# 面板改了 /usr/share 下的文件，PVE 升级会把它们覆盖；留一份版本号，
# 方便日后判断主机上装的到底是哪一版（uninstall 会随 CONF_DIR 一起清掉）
step "记录安装版本"
install -d -m 0755 "$CONF_DIR"
printf '%s\n' "$VERSION" >"$CONF_DIR/VERSION"
chmod 0644 "$CONF_DIR/VERSION"
say "已写入 $CONF_DIR/VERSION ($VERSION)"

# ---------- 校验缓存 ----------
step "校验 SMART 缓存"
CACHE_N=0
if [ -f "$CONF_DIR/disks.conf" ]; then
    CACHE_N=$(grep -c '^sd[0-9]' "$CONF_DIR/disks.conf" 2>/dev/null || true)
fi
say "设备清单: $CACHE_N 项"

MISSING=0
for i in $(seq 0 $((CACHE_N - 1))); do
    f="$RUNDIR/sd$i.json"
    if [ -s "$f" ]; then
        sz=$(stat -c%s "$f")
        say "  sd$i: ${sz} 字节"
        if grep -q '"model_name"' "$f" 2>/dev/null; then
            say "        型号: $(sed -n 's/.*"model_name": *"\([^"]*\)".*/\1/p' "$f" | head -1)"
        else
            say "        警告: 未取到型号，缓存内可能只有错误信息"
        fi
    else
        say "  sd$i: 缓存缺失 ($f)"
        MISSING=1
    fi
done

# 关键校验：www-data 必须能读缓存，这正是本方案要解决的问题
if [ "$CACHE_N" -gt 0 ] && command -v runuser >/dev/null 2>&1; then
    if runuser -u www-data -- test -r "$RUNDIR/sd0.json" 2>/dev/null; then
        say "权限校验: www-data 可读缓存（正常）"
    else
        rollback
        die "www-data 无法读取 $RUNDIR/sd0.json，面板会显示「未知」，已回滚"
    fi
fi

if [ "$MISSING" -eq 1 ] && [ "$CACHE_N" -gt 0 ]; then
    say "警告: 部分磁盘缓存缺失，面板对应行会显示「未知」"
fi

# ---------- 校验功耗 ----------
step "校验功耗缓存"
if [ ! -f "$RUNDIR/power.json" ]; then
    say "power.json: 缺失（面板功耗行会显示「未知」）"
else
    PW=$(cat "$RUNDIR/power.json" 2>/dev/null || true)
    case "$PW" in
        *'"ok":true'*)
            PKG=$(printf '%s' "$PW" | sed -n 's/.*"pkg_w": *\([0-9.]*\).*/\1/p')
            PSYS=$(printf '%s' "$PW" | sed -n 's/.*"psys_w": *\([0-9.]*\).*/\1/p')
            say "功耗采集: 正常（CPU 封装 ${PKG} W）"
            if [ -n "$PSYS" ]; then
                say "          整机 ${PSYS} W（psys 域可信）"
            else
                say "          本机 psys 域不可信（小于封装功耗），面板只显示封装功耗"
            fi
            ;;
        *unsupported*)
            say "功耗采集: 本机无 RAPL package 域，面板显示「本机不支持功耗读取」"
            ;;
        *)
            say "功耗采集: 尚未就绪（面板显示「采集中...」，5 秒内自愈）"
            ;;
    esac
    if command -v runuser >/dev/null 2>&1; then
        if runuser -u www-data -- test -r "$RUNDIR/power.json" 2>/dev/null; then
            say "权限校验: www-data 可读 power.json（正常）"
        else
            rollback
            die "www-data 无法读取 $RUNDIR/power.json，已回滚"
        fi
    fi
fi

# ---------- 重启服务 ----------
step "重启 pvedaemon / pveproxy"
systemctl restart pvedaemon pveproxy
sleep 2
systemctl is-active pvedaemon pveproxy 2>/dev/null | sed 's/^/    /' || true

# ---------- 验证 ----------
step "验证 API 输出"
API_JSON=$(pvesh get /nodes/localhost/status --output-format json 2>/dev/null || true)
for f in thermalstate cpuFreq powerState; do
    if printf '%s' "$API_JSON" | grep -q "\"$f\""; then
        say "$f: 正常"
    else
        say "$f: 缺失（请查看 journalctl -u pvedaemon）"
    fi
done
for i in $(seq 0 $((CACHE_N - 1))); do
    if printf '%s' "$API_JSON" | grep -q "\"sd$i\""; then
        say "sd$i: 正常"
    else
        say "sd$i: 缺失"
    fi
done

cat <<EOF

安装完成。

下一步：
  1. 浏览器打开 PVE 管理界面 https://<你的PVE地址>:8006
  2. 按 Shift+F5 强制刷新缓存（必须，否则看不到新内容）
  3. 在节点「摘要」面板查看 温度 / CPU频率 / 功耗 / 磁盘

工作原理：
  温度、频率  每次请求现读 sysfs（0444，不需要额外权限）
  功耗        energy_uj 是 root-only(0400)，由 $TIMER 以 root 读出累计
              微焦，与上一次采样差分后换算成瓦特，写入 $RUNDIR/power.json
  磁盘 SMART  同样由 $TIMER 以 root 采集到 $RUNDIR/
              面板侧读的都是 0644 普通文件，因此不需要给 www-data
              任何额外权限（无 sudo、无 disk 组、无 SUID）

常用命令：
  systemctl status $TIMER        查看定时器
  systemctl list-timers $TIMER   查看下次触发时间
  $COLLECTOR                     手工刷新一次缓存

卸载： ./uninstall.sh
备份： $BACKUP_DIR
EOF
