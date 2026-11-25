# pve-nodeinfo

在 Proxmox VE 节点的「摘要」面板中增加 **CPU 温度、CPU 频率、磁盘健康** 三行信息。

不装软件包、不设 SUID、不改订阅弹窗，只读取内核 `sysfs` 与 `smartctl` 的只读输出。

**当前版本：v1.0.0**

```
温度(°C)      Board: 28°C | CPU封装: 55°C | CPU0: 56°C | CPU1: 58°C | CPU2: 56°C | CPU3: 56°C
CPU频率(GHz)  3.1 | 3.0 | 2.9 | 3.0 | MAX: 3.4 | MIN: 0.7 | 调速器: PERFORMANCE
固态硬盘0      Great Wall GW560 128GB | 温度: 30°C | 通电: 1306时,次: 9 | SMART: 正常
```

---

## 一、版本概述

v1.0.0 是首个发布版本。它把 PVE 默认不显示的硬件状态（温度、实时频率、磁盘 SMART 健康度）补进节点摘要面板，方便在一台机器上同时看到负载与散热/健康状态，不必再单独 SSH 跑 `sensors` 或 `smartctl`。

与网上流传的一键脚本相比，本版本刻意做了**减法**：不安装依赖包、不给任何二进制加 SUID、不改动订阅提示相关文件、不写 `/tmp` 固定路径临时文件。改动的范围被压缩到「2 个 PVE 界面文件 + 1 个只读采集脚本」。

**实现方式**：在 `Nodes.pm` 的节点状态构造处追加 3+N 个只读字段；在 `pvemanagerlib.js` 的 `pveNodeStatus` 组件 items 数组末尾追加对应显示项，并按行数调整面板高度。所有插入点都带锚点断言，锚点不符立即退出，不盲改。

---

## 二、主要功能

| 功能 | 说明 |
|---|---|
| CPU 温度 | 读取 `coretemp` 的封装温度与各核心温度；同时显示主板 `acpitz` 温度。无需 `lm-sensors` |
| CPU 频率 | 各核心实时频率（GHz）、最小/最大频率、当前调速器（governor） |
| 磁盘健康 | 自动检测所有 `sd*` / `nvme*n*` / `vd*` 磁盘，逐块显示型号、温度、通电时间、通电次数、SMART 判定 |
| 磁盘自动识别 | 安装时扫描 `/sys/block`，按 `rotational` 自动标注「固态硬盘 N」或「机械硬盘 N」，并跳过可移动介质 |
| 优雅降级 | 任一字段取不到数据时显示占位文案，不会让面板报错或白屏 |
| 一键备份/回滚 | 安装前自动打包原文件并记录 sha256；卸载时校验还原是否与安装前完全一致 |
| 失败自愈 | 打补丁或语法自检失败时，安装脚本自动还原并重启服务 |

---

## 三、依赖要求

| 项目 | 要求 | 说明 |
|---|---|---|
| 操作系统 | Proxmox VE 8.x / 9.x | 已在 PVE 9.1.1 (Debian 13 trixie, kernel 6.17) 实测通过；PVE 7 及更早版本锚点结构不同，**不支持** |
| 权限 | root | 需要写 `/usr/share/` 下两个文件 |
| python3 | 3.6+ | PVE 自带，用于补丁脚本 |
| perl | 任意 5.x | PVE 自带，用于语法自检 |
| smartctl | 建议安装 | 通常随 PVE 自带；缺失时仅影响磁盘信息，温度与频率不受影响 |
| 网络 | **不需要** | 安装过程不联网、不下载任何东西 |
| lm-sensors | **不需要** | 本版本直接读 `sysfs`，不依赖该包 |
| linux-cpupower | **不需要**（可选） | 仅当你希望额外显示整包功耗时才需要，本版本未包含该功能 |

---

## 四、安装

```bash
tar xzf pve-nodeinfo-1.0.0.tar.gz
cd pve-nodeinfo-1.0.0
sudo ./install.sh
```

先看它要做什么（不写任何文件）：

```bash
sudo ./install.sh --dry-run
```

安装脚本会依次：检查环境 → 检测磁盘 → 备份原文件到 `/root/pve-nodeinfo-backup-<时间戳>/` → 部署采集脚本 → 打补丁 → `perl -c` 语法自检 → 重启 `pvedaemon` / `pveproxy` → 验证 API 字段。

**装完必须做的一步**：浏览器打开 `https://<你的PVE地址>:8006`，按 **`Shift+F5`** 强制刷新。改的是前端 JS 资源，不刷缓存看不到新内容。

---

## 五、卸载

```bash
sudo ./uninstall.sh
```

脚本会自动找最近一次备份并还原，然后用 `sha256sum -c` 校验是否与安装前完全一致，删除采集脚本，重启服务并确认字段已移除。

指定某个备份：`sudo ./uninstall.sh /root/pve-nodeinfo-backup-20260101-120000`

若备份目录被误删，可走官方包重装（需主机能访问软件源）：

```bash
apt install --reinstall pve-manager proxmox-widget-toolkit
systemctl restart pvedaemon pveproxy
```

---

## 六、使用注意事项

1. **必须强制刷新**：`Shift+F5`。否则浏览器仍使用旧的 `pvemanagerlib.js`，页面看起来「没变化」。
2. **会短暂中断 Web 管理界面**：安装/卸载都会重启 `pvedaemon` 与 `pveproxy`，期间管理页面会断连数秒。请避免正在做重要操作时执行。
3. **PVE 升级会覆盖改动**：`/usr/share/` 下的文件不属 conffile，`apt upgrade pve-manager` 会**静默覆盖**这两个文件，改动消失且不会报错。升级后重新执行 `sudo ./install.sh` 即可（脚本检测到旧安装会提示先卸载；实际上升级后标记已被覆盖，可直接重装）。
4. **不要重复运行安装脚本**：脚本会检测已有标记并拒绝执行，防止叠加注入。确需重装请先 `uninstall.sh`。
5. **单节点场景**：改动只作用于本节点文件。集群环境下需在**每台节点**分别执行。
6. **性能开销可忽略**：采集脚本只读 sysfs，实测单次调用约 0.01s；`smartctl` 约 0.02s。相比原社区脚本（每次轮询 fork `turbostat` + `sleep 0.25`）显著更轻。
7. **字段在 API 中可见**：数据通过 `/api2/json/nodes/<node>/status` 返回，任何已登录 PVE 的用户都能看到，与页面显示一致（包含磁盘序列号等 SMART 信息，注意多用户环境的可见性）。

---

## 七、已知问题

| 编号 | 问题 | 影响 | 处理建议 |
|---|---|---|---|
| #1 | 不显示整包功耗（PkgWatt） | 少一项数据 | 需额外安装 `linux-cpupower` 并加载 `msr` 模块；为减少系统改动本版本未包含 |
| #2 | 无风扇转速 | 部分机器缺少该行 | 取决于主板是否暴露 `fan*_input`；本版本测试机（N100）本身无风扇传感器，属硬件限制 |
| #3 | 仅支持 PVE 8.x / 9.x | 旧版本无法安装 | 更早版本锚点结构不同，脚本会明确报「不受支持」并退出，不会硬改 |
| #4 | 面板高度按行数估算（28px/行） | 极端情况下可能留白或轻微裁切 | 可在 `scripts/patch_pve_nodes.py` 中调整 `LINE_HEIGHT` 常量后重装 |
| #5 | 升级后改动丢失 | 需重新安装 | 见「使用注意事项」第 3 条 |
| #6 | 温度取不到时统一显示「未知」 | 无法区分「无传感器」与「采集失败」 | 可 SSH 执行 `/usr/local/bin/pve-hwinfo.sh thermal` 排查 |
| #7 | 仅显示磁盘当前瞬时温度 | 无历史曲线 | 本版本不做数据持久化，如需趋势请配合外部监控 |

---

## 八、目录结构

```
pve-nodeinfo-1.0.0/
├── README.md                    本文件：概述、功能、依赖、安装、注意事项、已知问题
├── CHANGELOG.md                 版本变更记录
├── VERSION                      版本号
├── LICENSE                      MIT
├── .gitattributes               强制 LF 行尾，避免 Windows 克隆后脚本报 "bad interpreter"
├── install.sh                   安装（含 --dry-run、自动备份、失败回滚、验证）
├── uninstall.sh                 卸载（校验式还原）
├── scripts/
│   ├── pve-hwinfo.sh            只读采集器，部署到 /usr/local/bin/，仅读 sysfs
│   └── patch_pve_nodes.py       补丁器，带锚点断言，支持 --dry-run / --check
└── docs/
    ├── DESIGN-NOTES.md          设计取舍与安全审查结论
    └── TESTING.md               测试与验证记录
```

---

## 九、安装后的文件变化

| 路径 | 类型 | 说明 |
|---|---|---|
| `/usr/share/perl5/PVE/API2/Nodes.pm` | 修改 | 追加 3+N 个只读字段 |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | 修改 | 追加显示项 + 调整面板高度 |
| `/usr/local/bin/pve-hwinfo.sh` | 新增 | 采集器，卸载时删除 |
| `/root/pve-nodeinfo-backup-<时间戳>/` | 新增 | 备份，卸载后可手动删除 |

**明确不触碰**：`/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js`（订阅提示相关）、任何二进制文件的权限位、`/etc/modules-load.d/`、`/tmp` 下的固定路径文件。

---

## 十、来源与许可

本项目为 MIT 许可，详见 `LICENSE`。

设计思路受 [a904055262/PVE-manager-status](https://github.com/a904055262/PVE-manager-status) 启发——同样是在节点摘要面板补硬件信息。**该上游仓库未声明任何开源许可证**，因此本版本未直接复制其代码，而是重新实现了采集与渲染：温度改用 `sysfs`（不依赖 `lm-sensors`）、磁盘改为安装时自动探测、去除了全部 `chmod +s` 与 `proxmoxlib.js` 改写、修正了原脚本的中文二次编码问题。

如果你计划将本项目用于商业分发，建议先确认上游授权情况，或完全独立地重写渲染部分以规避争议。

---

## 十一、免责声明

本脚本会修改 Proxmox VE 的系统文件，属于**非官方支持的改动**。虽然安装器提供了备份、失败回滚与校验式卸载，仍请你在生产环境部署前：

1. 先在测试节点验证；
2. 确认备份目录可读；
3. 避免在业务高峰执行（会重启 Web 服务）。

因使用本脚本造成的任何问题，作者不承担责任。
