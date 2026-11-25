#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在 PVE 节点状态面板中增加 温度 / CPU 频率 / 磁盘信息 显示。

本脚本做三件事，全部带锚点断言，锚点不符立即退出、不改任何文件：
  1) 生成 /etc/pve-nodeinfo/disks.conf（root 采集器与面板字段的对应关系）
  2) 向 Nodes.pm 注入 2+N 个只读字段（N = 自动检测到的磁盘数）
  3) 向 pvemanagerlib.js 的 pveNodeStatus items 数组注入显示项，并调整面板高度

不做的事（与原版社区脚本的重要区别）：
  - 不修改 proxmoxlib.js（订阅弹窗）
  - 不设置任何 SUID 位
  - 不给 www-data 加 sudo 权限或 disk 组
  - 不安装软件包、不加载 msr 模块
  - 不写 /tmp 临时文件

用法：
  python3 patch_pve_nodes.py --dry-run    # 只打印将要做什么
  python3 patch_pve_nodes.py              # 实际打补丁
  python3 patch_pve_nodes.py --check      # 检查当前安装状态
"""

import argparse
import os
import re
import sys

NODES_PM = "/usr/share/perl5/PVE/API2/Nodes.pm"
MANAGER_JS = "/usr/share/pve-manager/js/pvemanagerlib.js"
HELPER = "/usr/local/bin/pve-hwinfo.sh"
COLLECTOR = "/usr/local/bin/pve-nodeinfo-collect"
SMARTCTL = "/usr/sbin/smartctl"
CONF_DIR = "/etc/pve-nodeinfo"
DISKS_CONF = "/etc/pve-nodeinfo/disks.conf"
RUNDIR = "/run/pve-nodeinfo"
UNIT_DIR = "/etc/systemd/system"

MARK = "pve-nodeinfo"
LEGACY_MARKS = ("modbyshowtempfreq",)
LINE_HEIGHT = 28  # 每行占用高度(px)，沿用社区脚本的经验值

DEV_PATTERN = re.compile(r"^(sd[a-z]+|nvme\d+n\d+|vd[a-z]+)$")

NODES_ANCHOR = '        $res->{pveversion} = PVE::pvecfg::package() . "/" . PVE::pvecfg::version_text();\n'
JS_ANCHOR = "textField: 'pveversion',"
JS_ALIAS = "alias: 'widget.pveNodeStatus',"
JS_NODESTATUS = "nodeStatus: nodeStatus,"


def read_text(path):
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
        return fh.read()


def read_sys(path, default=""):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return default


def write_atomic(path, text):
    """保留原文件权限与属主，原子替换。"""
    st = os.stat(path)
    tmp = path + ".pve-nodeinfo.tmp"
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as fh:
        fh.write(text)
    os.chmod(tmp, st.st_mode & 0o7777)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except OSError:
        pass
    os.replace(tmp, path)


def detect_disks():
    """从 /sys/block 枚举真实块设备，排除可移动介质与虚拟设备。"""
    disks = []
    if not os.path.isdir("/sys/block"):
        return disks
    for name in sorted(os.listdir("/sys/block")):
        if not DEV_PATTERN.match(name):
            continue
        base = os.path.join("/sys/block", name)
        if not os.path.isdir(os.path.join(base, "device")):
            continue
        if read_sys(os.path.join(base, "removable")) == "1":
            continue
        sectors = read_sys(os.path.join(base, "size"), "0")
        try:
            size_gb = round(int(sectors) * 512 / (1024 ** 3))
        except ValueError:
            size_gb = 0
        disks.append(
            {
                "name": name,
                "dev": "/dev/" + name,
                "rotational": read_sys(os.path.join(base, "queue", "rotational"), "1") == "1",
                "model": read_sys(os.path.join(base, "device", "model")) or name,
                "size_gb": size_gb,
            }
        )
    return disks


def conf_text(disks):
    lines = [
        "# pve-nodeinfo 磁盘清单（由 install.sh 自动生成，勿手工编辑）",
        "# 格式: <面板字段名>=<块设备>，字段名与 Nodes.pm 注入的 $res->{sdN} 一一对应",
    ]
    for idx, disk in enumerate(disks):
        lines.append("sd%d=%s" % (idx, disk["dev"]))
    return "\n".join(lines) + "\n"


def write_disks_conf(disks):
    if not os.path.isdir(CONF_DIR):
        os.makedirs(CONF_DIR, 0o755)
    with open(DISKS_CONF, "w", encoding="utf-8") as fh:
        fh.write(conf_text(disks))
    os.chmod(DISKS_CONF, 0o644)


def disk_title(disk, idx):
    kind = "机械硬盘" if disk["rotational"] else "固态硬盘"
    return "%s%d" % (kind, idx)


PERL_DISK_BLOCK = """        # SMART 数据由 pve-nodeinfo-collect.timer 以 root 预采集到 %(run)s/
        # （API 请求运行在 www-data 身份下，无权直接读 /dev/sdX）
        $res->{sd%(idx)d} = do {
            my $f = '%(run)s/sd%(idx)d.json';
            my $c = '';
            if (open(my $fh, '<', $f)) { local $/; $c = <$fh>; close($fh); }
            $c // '';
        };
"""


def build_perl_block(disks):
    lines = ["", "        #" + MARK]
    lines.append('        $res->{thermalstate} = `%s thermal 2>/dev/null`;' % HELPER)
    lines.append('        $res->{cpuFreq} = `%s cpu 2>/dev/null`;' % HELPER)
    out = "\n".join(lines) + "\n"
    for idx in range(len(disks)):
        out += PERL_DISK_BLOCK % {"idx": idx, "run": RUNDIR}
    return out


JS_THERMAL = """
        //%(mark)s
        {
            itemId: 'thermal',
            colspan: 2,
            printBar: false,
            title: gettext('温度(°C)'),
            textField: 'thermalstate',
            value: '',
            renderer: function (value) {
                try {
                    if (!value) {
                        return Proxmox.Utils.unknownText;
                    }
                    let labels = {
                        'CPU Package': 'CPU封装',
                        Board: '主板',
                        WLAN: '无线',
                        NVMe: 'NVMe',
                        Fan: '风扇',
                    };
                    let parts = [];
                    String(value).split('\\n').forEach(function (line) {
                        let s = line.trim();
                        if (!s) {
                            return;
                        }
                        let m = s.match(/^(.+?):\\s*([+-]?[\\d.]+)$/);
                        if (!m) {
                            return;
                        }
                        let name = labels[m[1]] || m[1];
                        if (m[1] === 'Fan') {
                            parts.push(name + ': ' + m[2] + ' RPM');
                        } else {
                            parts.push(name + ': ' + Number(m[2]).toFixed(0) + '°C');
                        }
                    });
                    return parts.length ? parts.join(' | ') : Proxmox.Utils.unknownText;
                } catch (e) {
                    return Proxmox.Utils.unknownText;
                }
            },
        },
        {
            itemId: 'cpumhz',
            colspan: 2,
            printBar: false,
            title: gettext('CPU频率(GHz)'),
            textField: 'cpuFreq',
            value: '',
            renderer: function (v) {
                try {
                    if (!v) {
                        return Proxmox.Utils.unknownText;
                    }
                    let mhz = [];
                    let gov = '--';
                    let mn = '--';
                    let mx = '--';
                    String(v).split('\\n').forEach(function (line) {
                        let s = line.trim();
                        let i = s.indexOf('=');
                        if (i < 0) {
                            return;
                        }
                        let k = s.slice(0, i);
                        let val = s.slice(i + 1);
                        if (k === 'mhz') {
                            mhz.push((Number(val) / 1000).toFixed(1));
                        } else if (k === 'gov') {
                            gov = String(val).toUpperCase();
                        } else if (k === 'min') {
                            mn = (Number(val) / 1000).toFixed(1);
                        } else if (k === 'max') {
                            mx = (Number(val) / 1000).toFixed(1);
                        }
                    });
                    let freq = mhz.length ? mhz.join(' | ') : '--';
                    return freq + ' | MAX: ' + mx + ' | MIN: ' + mn + ' | 调速器: ' + gov;
                } catch (e) {
                    return Proxmox.Utils.unknownText;
                }
            },
        },
""" % {"mark": MARK}

JS_DISK = """
        {
            itemId: 'disk%(idx)d',
            colspan: 2,
            printBar: false,
            title: gettext('%(title)s'),
            textField: 'sd%(idx)d',
            value: '',
            renderer: function (value) {
                try {
                    if (value === undefined || value === null || !String(value).trim()) {
                        return Proxmox.Utils.unknownText;
                    }
                    let v = typeof value === 'string' ? JSON.parse(value) : value;
                    if (!v) {
                        return Proxmox.Utils.unknownText;
                    }
                    if (v.standy === true) {
                        return '休眠中';
                    }
                    // smartctl 的告警可能在顶层 messages，也可能在 smartctl.messages
                    let msgs = []
                        .concat(v.messages || [])
                        .concat((v.smartctl || {}).messages || [])
                        .map(function (m) { return (m && m.string) || ''; })
                        .filter(function (s) { return s !== ''; })
                        .join('；');
                    if (!v.model_name) {
                        if (/permission denied/i.test(msgs)) {
                            return '无法读取 SMART（权限不足）';
                        }
                        if (!Object.keys(v).length) {
                            return '未检测到该磁盘';
                        }
                        if (msgs) {
                            return '读取失败: ' + msgs.slice(0, 60);
                        }
                        return '未获取到磁盘信息';
                    }
                    let text = v.model_name;
                    let temp = v.temperature && v.temperature.current;
                    if (temp !== undefined) {
                        text += ' | 温度: ' + temp + '°C';
                    }
                    let pot = v.power_on_time && v.power_on_time.hours;
                    let poth = v.power_cycle_count;
                    if (pot !== undefined) {
                        text += ' | 通电: ' + pot + '时' + (poth ? ',次: ' + poth : '');
                    }
                    let smart = v.smart_status && v.smart_status.passed;
                    if (smart !== undefined) {
                        text += ' | SMART: ' + (smart ? '正常' : '警告!');
                    }
                    return text;
                } catch (e) {
                    return Proxmox.Utils.unknownText;
                }
            },
        },
"""


def build_js_block(disks):
    out = JS_THERMAL
    for idx, disk in enumerate(disks):
        out += JS_DISK % {"idx": idx, "title": disk_title(disk, idx)}
    return out


def find_legacy(path, text):
    for mark in LEGACY_MARKS:
        if mark in text:
            return mark
    return None


def patch_nodes_pm(text, disks, dry):
    if MARK in text:
        return None, "Nodes.pm 已包含 %s 标记，已打过补丁" % MARK
    legacy = find_legacy(NODES_PM, text)
    if legacy:
        return None, "Nodes.pm 含旧版标记 %r，请先执行 uninstall.sh" % legacy
    if text.count(NODES_ANCHOR) != 1:
        return None, "Nodes.pm 锚点数量异常(%d)，当前 PVE 版本不受支持" % text.count(NODES_ANCHOR)

    block = build_perl_block(disks)
    if dry:
        return text, "将注入 %d 个字段（温度/频率 + %d 个磁盘，读缓存文件）" % (
            2 + len(disks),
            len(disks),
        )
    return text.replace(NODES_ANCHOR, NODES_ANCHOR + block, 1), "注入 %d 个采集字段" % (
        2 + len(disks)
    )


def patch_manager_js(text, disks, dry):
    if MARK in text:
        return None, "pvemanagerlib.js 已包含 %s 标记，已打过补丁" % MARK
    legacy = find_legacy(MANAGER_JS, text)
    if legacy:
        return None, "pvemanagerlib.js 含旧版标记 %r，请先执行 uninstall.sh" % legacy

    lines = text.split("\n")
    hits = [i for i, line in enumerate(lines) if line.strip() == JS_ANCHOR]
    if len(hits) != 1:
        return None, "pveversion 锚点数量异常(%d)，当前 PVE 版本不受支持" % len(hits)

    close = None
    for i in range(hits[0], hits[0] + 4):
        if lines[i].strip() == "},":
            close = i
            break
    if close is None:
        return None, "pveversion 条目未在 4 行内闭合"
    if lines[close + 1].strip() != "],":
        return None, "items 数组结构与预期不符: %r" % lines[close + 1]

    items = 2 + len(disks)
    add_height = LINE_HEIGHT * items

    # 高度调整的目标行需要在插入前定位，插入会把行号推后
    alias = [i for i, line in enumerate(lines) if line.strip() == JS_ALIAS]
    if len(alias) != 1:
        return None, "widget.pveNodeStatus 锚点数量异常(%d)" % len(alias)
    height_idx = None
    for i in range(alias[0], alias[0] + 8):
        s = lines[i].strip()
        if s.startswith("height:") and s.endswith(","):
            height_idx = i
            break
    if height_idx is None:
        return None, "未找到 pveNodeStatus 的 height 配置"

    ns = [i for i, line in enumerate(lines) if line.strip() == JS_NODESTATUS]
    minheight_idx = None
    if len(ns) == 1:
        for i in range(ns[0], ns[0] + 15):
            if lines[i].strip().startswith("minHeight:"):
                minheight_idx = i
                break

    height_old = int(lines[height_idx].strip()[7:].strip().rstrip(","))
    height_new = height_old + add_height

    if dry:
        msg = "将在 items 末尾插入 %d 个显示项；height %d -> %d" % (items, height_old, height_new)
        if minheight_idx is not None:
            mh_old = int(lines[minheight_idx].strip()[10:].strip().rstrip(","))
            msg += "；minHeight %d -> %d" % (mh_old, mh_old + add_height)
        return text, msg

    lines[height_idx] = lines[height_idx].replace(
        "height: %d," % height_old, "height: %d," % height_new, 1
    )
    if minheight_idx is not None:
        mh_old = int(lines[minheight_idx].strip()[10:].strip().rstrip(","))
        lines[minheight_idx] = lines[minheight_idx].replace(
            "minHeight: %d" % mh_old, "minHeight: %d" % (mh_old + add_height), 1
        )

    close = None
    hits = [i for i, line in enumerate(lines) if line.strip() == JS_ANCHOR]
    for i in range(hits[0], hits[0] + 4):
        if lines[i].strip() == "},":
            close = i
            break

    block = build_js_block(disks).strip("\n").split("\n")
    lines[close + 1 : close + 1] = [""] + block

    note = "插入 %d 个显示项，height %d -> %d" % (items, height_old, height_new)
    if minheight_idx is None:
        note += "（未找到 minHeight，跳过）"
    else:
        note += "，minHeight %d -> %d" % (mh_old, mh_old + add_height)
    return "\n".join(lines), note


def do_check():
    ok = True
    for path in (NODES_PM, MANAGER_JS):
        if not os.path.exists(path):
            print("缺失文件: %s" % path)
            ok = False
            continue
        text = read_text(path)
        if MARK in text:
            print("已安装: %s" % path)
        elif find_legacy(path, text):
            print("检测到旧版补丁: %s" % path)
            ok = False
        else:
            print("未安装: %s" % path)
            ok = False

    for path, label in ((HELPER, "采集脚本"), (COLLECTOR, "SMART 采集器")):
        exists = os.path.exists(path)
        print("%s: %s (%s)" % (label, "存在" if exists else "缺失", path))
        if not exists:
            ok = False

    if os.path.exists(DISKS_CONF):
        entries = [
            ln for ln in read_text(DISKS_CONF).splitlines() if ln.strip() and not ln.startswith("#")
        ]
        print("设备清单: %d 项 (%s)" % (len(entries), DISKS_CONF))
    else:
        print("设备清单: 缺失 (%s)" % DISKS_CONF)
        ok = False

    for unit in ("pve-nodeinfo-collect.service", "pve-nodeinfo-collect.timer"):
        exists = os.path.exists(os.path.join(UNIT_DIR, unit))
        print("systemd 单元 %s: %s" % (unit, "存在" if exists else "缺失"))
        if not exists:
            ok = False

    if os.path.isdir(RUNDIR):
        print("缓存目录: 存在 (%s)" % RUNDIR)
    else:
        print("缓存目录: 缺失 (%s)" % RUNDIR)
        ok = False

    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description="PVE 节点状态面板信息增强补丁")
    parser.add_argument("--dry-run", action="store_true", help="只显示将要做的改动")
    parser.add_argument("--check", action="store_true", help="检查当前安装状态")
    args = parser.parse_args()

    if args.check:
        return do_check()

    if os.geteuid() != 0:
        print("必须以 root 运行")
        return 1

    for path in (NODES_PM, MANAGER_JS):
        if not os.path.exists(path):
            print("找不到 %s，这不是 PVE 主机？" % path)
            return 1

    disks = detect_disks()
    print("检测到 %d 块磁盘:" % len(disks))
    for idx, disk in enumerate(disks):
        print(
            "  [%d] %s  %s  %sGB  %s"
            % (
                idx,
                disk["dev"],
                "机械" if disk["rotational"] else "固态",
                disk["size_gb"],
                disk["model"],
            )
        )
    if not disks:
        print("  未检测到磁盘，仅显示温度与频率")
    elif not os.path.exists(SMARTCTL):
        print("  警告: 未找到 %s，磁盘信息将显示为「未知」" % SMARTCTL)

    plan = []
    new_nodes, msg_nodes = patch_nodes_pm(read_text(NODES_PM), disks, args.dry_run)
    print("[Nodes.pm] " + msg_nodes)
    if new_nodes is None:
        return 1
    plan.append((NODES_PM, new_nodes))

    new_js, msg_js = patch_manager_js(read_text(MANAGER_JS), disks, args.dry_run)
    print("[pvemanagerlib.js] " + msg_js)
    if new_js is None:
        return 1
    plan.append((MANAGER_JS, new_js))

    if args.dry_run:
        print("[%s]" % DISKS_CONF)
        for line in conf_text(disks).splitlines():
            print("  " + line)
        print("\n--dry-run：未写入任何文件")
        return 0

    for path, text in plan:
        write_atomic(path, text)
    write_disks_conf(disks)
    print("\n补丁已写入，设备清单已生成。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
