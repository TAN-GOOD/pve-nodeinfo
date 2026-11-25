# pve-nodeinfo

在 Proxmox VE 节点的「摘要」面板中增加 **CPU 温度、CPU 频率、磁盘健康** 三行信息。

不装软件包、不设 SUID、**不给 `www-data` 任何额外权限**、不改订阅弹窗。

**当前版本：v1.1.0**

```
温度(°C)      Board: 28°C | CPU封装: 55°C | CPU0: 56°C | CPU1: 58°C | CPU2: 56°C | CPU3: 56°C
CPU频率(GHz)  3.1 | 3.0 | 2.9 | 3.0 | MAX: 3.4 | MIN: 0.7 | 调速器: PERFORMANCE
固态硬盘0      CT500MX500SSD1 | 温度: 30°C | 通电: 1306时,次: 9 | SMART: 正常
```

---

## 一、版本概述

v1.1.0 在 v1.0.0 的基础上修掉一个**在真实环境中必然出现**的缺陷：面板的磁盘行显示「找不到硬盘，可能已直通或被卸载」，而硬盘其实完全正常。

根因不是硬盘，也不是本项目的探测逻辑，而是 **PVE 的权限模型**：

- `/dev/sdX` 的权限是 `brw-rw---- root:disk`；
- `pvedaemon` 主进程虽然是 root，但**处理 API 请求的 worker 会降权成 `www-data`**；
- 于是 `smartctl` 读不到设备，只返回一条 `Permission denied`，JSON 里没有 `model_name`；
- v1.0.0 的渲染器看到「没有型号」就直接判定成「找不到硬盘」，给出了误导性的结论。

v1.1.0 改为 **root 预采集 + 面板只读缓存文件**：由一个 systemd timer 每 5 秒以 root 身份跑一次 `smartctl`，结果写到 `/run/pve-nodeinfo/*.json`（权限 `0644`），API 侧只读普通文件。这样既不降低安全性（不配 sudo、不加 `disk` 组、不设 SUID），又保证了数据正确，还顺带把「每个浏览器标签页每 3 秒 fork 一次 `smartctl`」的开销降了下来。

同时修正了文案：现在会如实区分「权限不足」「设备不存在」「读取失败」「缓存未就绪」四种情况，不再一律说成「找不到硬盘」。

---

## 二、主要功能

| 功能 | 说明 |
|---|---|
| CPU 温度 | 读取 `coretemp` 的封装温度与各核心温度，同时显示主板 `acpitz` 温度。无需 `lm-sensors` |
| CPU 频率 | 各核心实时频率（GHz）、最小/最大频率、当前调速器（governor） |
| 磁盘健康 | 自动检测所有 `sd*` / `nvme*n*` / `vd*`，逐块显示型号、温度、通电时间、通电次数、SMART 判定 |
| 磁盘自动识别 | 安装时扫描 `/sys/block`，按 `rotational` 标注「固态硬盘 N」/「机械硬盘 N」，并跳过可移动介质 |
| 权限无关 | 磁盘数据由 root 定时预采集，面板侧只读 `0644` 文件；**不修改任何账户权限** |
| 精确降级 | 缺数据时区分场景：`未知` / `未检测到该磁盘` / `无法读取 SMART（权限不足）` / `读取失败: …` |
| 采集抖动抑制 | `smartctl` 偶发失败时保留上一次的有效数据，面板不会在「正常」与「未检测到」之间跳变 |
| 一键备份/回滚 | 安装前打包原文件并记录 sha256；卸载时校验还原是否与安装前完全一致 |
| 失败自愈 | 打补丁、语法自检、采集器启动、权限校验任一环节失败，安装脚本自动完整回滚（含 systemd 单元） |

---

## 三、依赖要求

| 项目 | 要求 | 说明 |
|---|---|---|
| 操作系统 | Proxmox VE 8.x / 9.x | 已在 PVE 9.1.1（Debian 13 trixie，kernel 6.17）实测通过；PVE 7 及更早版本锚点结构不同，**不支持** |
| 权限 | root | 需要写 `/usr/share/` 下两个文件、安装 systemd 单元 |
| systemd | 必需 | 定时采集依赖 `systemd.timer`（PVE 自带） |
| python3 | 3.6+ | PVE 自带，用于补丁脚本 |
| perl | 任意 5.x | PVE 自带，用于语法自检 |
| smartctl | 建议安装 | 通常随 PVE 自带（`smartmontools`）；缺失时仅影响磁盘行，温度与频率不受影响 |
| 网络 | **不需要** | 安装过程不联网、不下载任何东西 |
| lm-sensors | **不需要** | 直接读 `sysfs` |
| linux-cpupower | **不需要**（可选） | 仅在希望显示整包功耗时才需要，本版本未包含该功能 |

**新增的常驻资源**：一个 systemd timer，每 5 秒执行一次约 20ms 的采集（`Nice=10`、`IOSchedulingClass=idle`）。

---

## 四、安装

```bash
tar xzf pve-nodeinfo-1.1.0.tar.gz
cd pve-nodeinfo-1.1.0
sudo ./install.sh
```

先看它要做什么（不写任何文件）：

```bash
sudo ./install.sh --dry-run
```

安装脚本会依次：

1. 检查环境（root / PVE / python3 / systemd / 发布包完整性）
2. 检测磁盘并打印清单
3. 备份 `Nodes.pm` 与 `pvemanagerlib.js` 到 `/root/pve-nodeinfo-backup-<时间戳>/`
4. 部署两个采集脚本，生成 `/etc/pve-nodeinfo/disks.conf`
5. 打补丁（`Nodes.pm` + `pvemanagerlib.js`）
6. `perl -c` 语法自检
7. 安装并启用 systemd timer，先手工跑一次采集
8. **校验缓存内容，并确认 `www-data` 能读取缓存**（这一步失败会自动回滚）
9. 重启 `pvedaemon` / `pveproxy`，验证 API 字段

**装完必须做的一步**：浏览器打开 `https://<你的PVE地址>:8006`，按 **`Shift+F5`** 强制刷新。改的是前端 JS 资源，不刷缓存看不到新内容。

---

## 五、卸载

```bash
sudo ./uninstall.sh
```

脚本会：停用并移除 systemd timer/service → 从最近备份还原两个 PVE 文件 → `sha256sum -c` 校验 → 删除采集器、`/etc/pve-nodeinfo`、`/run/pve-nodeinfo` → 重启服务并确认字段已移除。

指定某个备份：`sudo ./uninstall.sh /root/pve-nodeinfo-backup-20260101-120000`

若备份目录被误删，可走官方包重装（需主机能访问软件源）：

```bash
apt install --reinstall pve-manager proxmox-widget-toolkit
systemctl restart pvedaemon pveproxy
```

---

## 六、工作原理与权限模型

这一节解释「为什么需要一个 root 采集器」，因为它是本版本与常见脚本最大的差别。

```
      root 域                                www-data 域
 ┌────────────────────────┐          ┌────────────────────────────┐
 │ pve-nodeinfo-collect   │  写入    │ pvedaemon API worker       │
 │ (systemd timer, 5s)    │ ───────► │ 读 /run/pve-nodeinfo/*.json│
 │  smartctl /dev/sda -j  │ 0644     │  （普通文件，可读）        │
 └────────────────────────┘          └────────────────────────────┘
              │                                     │
         读 /dev/sda                         不接触块设备
      (root:disk, 0660)                    (无需 sudo / disk 组)
```

常见做法有三种，本项目选了第一种：

| 做法 | 代价 | 本项目 |
|---|---|---|
| root 预采集 → 写 `0644` 缓存 | 数据最多滞后 5 秒 | ✅ 采用 |
| 给 `www-data` 配 `sudo` 白名单执行 `smartctl` | Web 用户获得执行面（可读任意盘、可发起自检） | ❌ |
| `usermod -aG disk www-data` | `www-data` 获得**所有块设备读写权限**，Web 一旦被攻破可直接读虚拟机磁盘镜像 | ❌ |

缓存目录 `/run` 是 tmpfs，**重启后清空**，由 timer 在开机 15 秒后自动填充。这段窗口内磁盘行会显示「未知」，属预期行为。

---

## 七、使用注意事项

1. **必须强制刷新**：`Shift+F5`。否则浏览器仍用旧的 `pvemanagerlib.js`。
2. **会短暂中断 Web 管理界面**：安装/卸载都会重启 `pvedaemon` 与 `pveproxy`，期间管理页面断连数秒。
3. **PVE 升级会覆盖改动**：`/usr/share/` 下的文件不属 conffile，`apt upgrade pve-manager` 会**静默覆盖**这两个文件，改动消失且不报错。升级后重新执行 `sudo ./install.sh` 即可。
4. **升级本项目**：先 `./uninstall.sh`，再装新版。安装脚本检测到已有标记会拒绝执行，防止叠加注入。
5. **不要手工删 `/run/pve-nodeinfo`**：删了也没关系，5 秒内会重建，但这期间是「未知」。
6. **单节点场景**：改动只作用于本节点文件。集群环境需在**每台节点**分别执行。
7. **性能开销**：温度/频率为 sysfs 直读（约 10ms/次）；磁盘为每 5 秒一次 `smartctl`（约 20ms，`Nice=10` 且 `IOSchedulingClass=idle`）。总体远低于原社区脚本（每次轮询 fork `turbostat` + `sleep 0.25`）。
8. **字段在 API 中可见**：数据通过 `/api2/json/nodes/<node>/status` 返回，任何已登录 PVE 的用户都能看到，**包含磁盘型号、序列号等 SMART 原始字段**。多用户环境请注意可见性。

---

## 八、已知问题

| 编号 | 问题 | 影响 | 处理建议 |
|---|---|---|---|
| #1 | 磁盘数据最多滞后 5 秒 | 对健康度观察无实际影响 | 需要立即刷新时执行 `sudo /usr/local/bin/pve-nodeinfo-collect` |
| #2 | 重启后约 15 秒内磁盘行显示「未知」 | 开机瞬间的短暂状态 | 属预期；`/run` 为 tmpfs，需等 timer 首次采集 |
| #3 | 不显示整包功耗（PkgWatt） | 少一项数据 | 需额外安装 `linux-cpupower` 并加载 `msr`；为减少系统改动未包含 |
| #4 | 无风扇转速 | 部分机器缺少该行 | 取决于主板是否暴露 `fan*_input`；测试机（N100）本身无该传感器 |
| #5 | 仅支持 PVE 8.x / 9.x | 旧版本无法安装 | 锚点结构不同时脚本明确报「不受支持」并退出，不会硬改 |
| #6 | 面板高度按行数估算（28px/行） | 极端情况可能留白或轻微裁切 | 调整 `scripts/patch_pve_nodes.py` 的 `LINE_HEIGHT` 后重装 |
| #7 | 升级 PVE 后改动丢失 | 需重新安装 | 见「注意事项」第 3 条 |
| #8 | `smartctl` 缺失时磁盘行显示「未知」 | 无法区分「没装工具」与「读不到盘」 | 执行 `sudo /usr/local/bin/pve-nodeinfo-collect` 无输出即为缺工具，装 `smartmontools` 即可 |
| #9 | 仅显示磁盘当前瞬时温度 | 无历史曲线 | 本版本不做数据持久化 |

---

## 九、目录结构

```
pve-nodeinfo-1.1.0/
├── README.md                    本文件
├── CHANGELOG.md                 版本变更记录
├── VERSION                      版本号
├── LICENSE                      MIT
├── .gitattributes               强制 LF 行尾，避免 Windows 克隆后脚本报 "bad interpreter"
├── install.sh                   安装（--dry-run、自动备份、失败回滚、缓存与权限校验）
├── uninstall.sh                 卸载（校验式还原，含 systemd 清理）
├── scripts/
│   ├── pve-hwinfo.sh            温度/频率采集器（只读 sysfs）
│   ├── pve-nodeinfo-collect     SMART 采集器（root 运行，写 /run/pve-nodeinfo/）
│   └── patch_pve_nodes.py       补丁器，带锚点断言，支持 --dry-run / --check
├── systemd/
│   ├── pve-nodeinfo-collect.service
│   └── pve-nodeinfo-collect.timer
└── docs/
    ├── DESIGN-NOTES.md          设计取舍与安全审查结论
    └── TESTING.md               测试与验证记录
```

---

## 十、安装后的文件变化

| 路径 | 类型 | 说明 |
|---|---|---|
| `/usr/share/perl5/PVE/API2/Nodes.pm` | 修改 | 追加 2+N 个只读字段 |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | 修改 | 追加显示项 + 调整面板高度 |
| `/usr/local/bin/pve-hwinfo.sh` | 新增 | 温度/频率采集器 |
| `/usr/local/bin/pve-nodeinfo-collect` | 新增 | SMART 采集器 |
| `/etc/pve-nodeinfo/disks.conf` | 新增 | 设备清单（`sd0=/dev/sda` 形式） |
| `/etc/systemd/system/pve-nodeinfo-collect.{service,timer}` | 新增 | 定时采集 |
| `/run/pve-nodeinfo/*.json` | 运行时 | SMART 缓存（tmpfs，重启清空） |
| `/root/pve-nodeinfo-backup-<时间戳>/` | 新增 | 备份，确认无误后可手动删除 |

**明确不触碰**：`/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js`（订阅提示相关）、任何二进制文件的权限位、`/etc/sudoers*`、用户组关系、`/etc/modules-load.d/`、`/tmp` 下的固定路径文件。

---

## 十一、来源与许可

本项目为 MIT 许可，详见 `LICENSE`。

设计思路受 [a904055262/PVE-manager-status](https://github.com/a904055262/PVE-manager-status) 启发——同样是在节点摘要面板补硬件信息。**该上游仓库未声明任何开源许可证**，因此本版本未复制其代码，而是重新实现了采集与渲染：温度改用 `sysfs`（不依赖 `lm-sensors`）、磁盘改为安装时自动探测 + root 预采集、去除了全部 `chmod +s` 与 `proxmoxlib.js` 改写、修正了原脚本的中文二次编码问题。

如果你计划将本项目用于商业分发，建议先确认上游授权情况，或完全独立地重写渲染部分以规避争议。

---

## 十二、免责声明

本脚本会修改 Proxmox VE 的系统文件，属于**非官方支持的改动**。虽然安装器提供了备份、失败回滚与校验式卸载，仍建议：

1. 先在测试节点验证；
2. 确认备份目录可读；
3. 避免在业务高峰执行（会重启 Web 服务）。

因使用本脚本造成的任何问题，作者不承担责任。
