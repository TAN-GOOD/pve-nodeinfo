# pve-nodeinfo

在 Proxmox VE 节点的「摘要」面板中增加 **CPU 温度、CPU 频率、CPU 功耗、磁盘健康** 四行信息。

不装软件包、不设 SUID、**不给 `www-data` 任何额外权限**、不改订阅弹窗。

**当前版本：v1.2.0**

```
温度(°C)      Board: 28°C | CPU封装: 55°C | CPU0: 56°C | CPU1: 58°C | CPU2: 56°C | CPU3: 56°C
CPU频率(GHz)  3.1 | 3.0 | 2.9 | 3.0 | MAX: 3.4 | MIN: 0.7 | 调速器: PERFORMANCE
功耗(W)       3.9 W
固态硬盘0      CT500MX500SSD1 | 温度: 30°C | 通电: 1306时,次: 9 | SMART: 正常
```

`psys` 域可信的主板会显示为 `3.9 W | 整机: 14.2 W`。

---

## 🚀 一句话安装

SSH 登录 PVE 主机（或在 PVE 网页版的 Shell 里），**按你的网络情况选一条**粘贴即可。

### 国内用户（无梯子 / 无代理）— 推荐

```bash
curl -fsSL https://gitee.com/T510/pve-nodeinfo/raw/main/install-online.sh | bash -s -- --cn
```

- 脚本和安装包**都从 Gitee 国内节点取**，不需要代理、不需要改 DNS，速度正常；
- 万一 Gitee 上没有对应版本，会自动退回国内加速镜像，不会卡在半路；
- 内容依然要过 SHA256 校验，镜像改不动包。

> `bash -s -- --cn` 是把 `--cn` 参数传给脚本，含义是「走国内源」。

### 国外 / 能直连 GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/TAN-GOOD/pve-nodeinfo/main/install-online.sh | bash
```

- 直连 GitHub 官方源，中间没有第三方环节；
- 能打开 GitHub 但下载很慢时，改用 `| bash -s -- --mirror` 走加速镜像。

### 两条命令怎么选

| | 国内版（`--cn`） | 国外版 |
|---|---|---|
| 脚本来源 | Gitee | GitHub raw |
| 安装包来源 | Gitee，失败自动退回国内镜像 | GitHub 官方 |
| 需要梯子/代理 | **不需要** | 不需要（能访问 GitHub 即可） |
| 典型场景 | 中国大陆家庭宽带、公司/学校网络、国内机房 | 海外 VPS、已配好代理的环境 |

**全程不需要输入任何内容。** 脚本会自动完成：环境检查 → 依赖补齐（缺 `smartmontools` 会尝试自动安装）→ 网络测试 → 下载发布包 → SHA256 校验 → 安装 → 9 项结果验证。每一步都有中文进度和 ✔/✘ 标记。

安装过程中任何一步失败，都会在**卸载旧版本之前**停下并打印「原因 / 原始错误 / 怎么解决」，所以**不会把你现在能用的版本弄坏**。重复运行也是安全的：同版本直接跳过，不同版本先卸载再装。

装完在浏览器打开 `https://<你的PVE地址>:8006`，按 **`Shift + F5`** 强制刷新，节点「摘要」面板就会多出这 4 行：

```
温度(°C)      Board: 28°C | CPU封装: 55°C | CPU0: 56°C | CPU1: 58°C | ...
CPU频率(GHz)  3.1 | 3.0 | 2.9 | 3.0 | MAX: 3.4 | MIN: 0.7 | 调速器: PERFORMANCE
功耗(W)       3.9 W
固态硬盘0      CT500MX500SSD1 | 温度: 30°C | 通电: 1306时,次: 9 | SMART: 正常
```

### 其他常用操作

先把脚本存到本地，之后反复用（国内用户用第一条，国外用户用第二条）：

```bash
# 国内用户
curl -fsSL https://gitee.com/T510/pve-nodeinfo/raw/main/install-online.sh -o /tmp/pni.sh

# 国外用户
curl -fsSL https://raw.githubusercontent.com/TAN-GOOD/pve-nodeinfo/main/install-online.sh -o /tmp/pni.sh
```

然后按需执行（**国内用户请给联网的命令加 `--cn`**）：

```bash
bash /tmp/pni.sh --doctor --cn      # 只体检，不下载、不安装、不改任何文件
bash /tmp/pni.sh --dry-run --cn     # 预演安装流程，不写任何文件
bash /tmp/pni.sh --force --cn       # 强制重装（先卸载再装）
bash /tmp/pni.sh --uninstall        # 卸载（PVE 升级前务必执行，不需要联网）
```

指定版本、离线安装、加速镜像等**全部参数见[第四节](#四安装)**。

---

## 一、版本概述

### v1.2.0：新增功耗显示

面板新增 **功耗(W)** 行，数据来自 Intel RAPL 的 `package-0` 域，即 **CPU 封装功耗**（与 `turbostat` 的 PkgWatt 同源）。测试平台 Intel N100 空闲约 3.5~4.2 W，满载随负载实时变化。

不安装 `linux-cpupower`、不加载额外内核模块、不需要 `turbostat` —— 直接读 `/sys/class/powercap/*/energy_uj`（PVE 自带的 `intel_rapl_msr` 模块已经提供）。真正的难点在权限和换算：

- `energy_uj` 的权限是 **`-r-------- root root`**，`www-data` 连读都读不到，因此和磁盘走同一条通路：**root 预采集 → 写 `0644` 缓存 → 面板只读**。
- 它记录的是「自开机累计微焦」，**不是功率**。要得到瓦特必须两次采样差分；而采集器每 5 秒被 systemd 重新拉起、没有内存状态，所以把上次的累计值与单调时间戳存进 `/run/pve-nodeinfo/.power.state`。
- 计数器会在 `max_energy_range_uj` 处回绕，差值转负时按该值折算，避免突然出现负功率或上亿瓦。

另外做了两处防错：

- **`psys`（整机域）可信性校验**。`psys` 物理上必然不小于 CPU 封装，只有满足 `psys ≥ 封装 × 0.85` 才显示「整机: xx W」。实测部分 N100 主板没有把 VR 电流信号接出来，`psys` 恒为 `0.32 W` 这种退化值 —— 若不校验，面板会显示一个比封装功耗还小的「整机功耗」。
- **合理性闸门**。采样窗口超过 60 秒（中途停采、休眠）或算出超过 2000 W 时丢弃本次结果。

### v1.1.0 的背景（架构由来）

v1.1.0 修掉了一个**在真实环境中必然出现**的缺陷：面板的磁盘行显示「找不到硬盘，可能已直通或被卸载」，而硬盘其实完全正常。

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
| CPU 功耗 | Intel RAPL `package-0` 域，两次采样差分得到封装功耗（W）；`psys` 域可信时附加显示整机功耗。**不需要 `linux-cpupower`、`msr-tools` 或 `turbostat`** |
| 磁盘健康 | 自动检测所有 `sd*` / `nvme*n*` / `vd*`，逐块显示型号、温度、通电时间、通电次数、SMART 判定 |
| 磁盘自动识别 | 安装时扫描 `/sys/block`，按 `rotational` 标注「固态硬盘 N」/「机械硬盘 N」，并跳过可移动介质 |
| 权限无关 | 磁盘与功耗由 root 定时预采集，面板侧只读 `0644` 文件；**不修改任何账户权限** |
| 精确降级 | 缺数据时区分场景：`未知` / `采集中...` / `本机不支持功耗读取` / `未检测到该磁盘` / `无法读取 SMART（权限不足）` / `读取失败: …` |
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
| smartctl | 建议安装 | 通常随 PVE 自带（`smartmontools`）；缺失时仅影响磁盘行，温度、频率与功耗不受影响 |
| 网络 | **不需要** | 安装过程不联网、不下载任何东西 |
| lm-sensors | **不需要** | 直接读 `sysfs` |
| linux-cpupower | **不需要** | 功耗直接读 `/sys/class/powercap/*/energy_uj`，PVE 自带的 `intel_rapl_msr` 已提供该接口 |
| msr-tools / turbostat | **不需要** | 不加载额外模块，不 fork 外部进程 |

**新增的常驻资源**：一个 systemd timer，每 5 秒执行一次约 20ms 的采集（`Nice=10`、`IOSchedulingClass=idle`）。

---

## 四、安装

两种方式效果完全相同。**只想快点用上就选方式 A。**

### 方式 A：一句话安装（推荐）

命令见本文开头的「🚀 一句话安装」。下面是它的全部可选参数：

| 场景 | 参数 |
|---|---|
| 只体检，不改动 | `--doctor` |
| 预演，不写任何文件 | `--dry-run` |
| 强制重装 | `--force` |
| 卸载（**升级 PVE 前必做**） | `--uninstall` |
| 指定版本 | `--version 1.2.0` |
| 离线安装（用已下载的包） | `--pkg /tmp/pve-nodeinfo-1.2.0.tar.gz` |
| 直连 GitHub 很慢 | `--mirror` |

> `--mirror` 会额外尝试 `ghfast.top` 等第三方加速镜像。**所有来源都必须通过 SHA256 校验**，镜像无法篡改内容 —— 校验值取自 GitHub API 的 `digest` 字段，API 不可用时回退到脚本内置表。

主机出网需要代理时：

```bash
export https_proxy=http://<代理IP>:<端口>
export http_proxy=http://<代理IP>:<端口>
curl -fsSL https://raw.githubusercontent.com/TAN-GOOD/pve-nodeinfo/main/install-online.sh | bash
```

### 方式 B：手动下载安装

```bash
tar xzf pve-nodeinfo-1.2.0.tar.gz
cd pve-nodeinfo-1.2.0
sudo ./install.sh
```

先看它要做什么（不写任何文件）：

```bash
sudo ./install.sh --dry-run
```

安装脚本会依次：

1. 检查环境（root / PVE / python3 / systemd / 发布包完整性）
2. 检测磁盘并打印清单，探测是否存在 RAPL `package` 域
3. 备份 `Nodes.pm` 与 `pvemanagerlib.js` 到 `/root/pve-nodeinfo-backup-<时间戳>/`
4. 部署两个采集脚本，生成 `/etc/pve-nodeinfo/disks.conf`
5. 打补丁（`Nodes.pm` + `pvemanagerlib.js`）
6. `perl -c` 语法自检
7. 安装并启用 systemd timer，先手工跑**两次**采集（第一次建立功耗差分基线，第二次才有瓦数）
8. 写入 `/etc/pve-nodeinfo/VERSION`，便于日后确认主机上的版本
9. **校验缓存内容，并确认 `www-data` 能读取缓存**（这一步失败会自动回滚）
10. 重启 `pvedaemon` / `pveproxy`，验证 API 字段

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
       root 域                                  www-data 域
 ┌───────────────────────────┐          ┌──────────────────────────────┐
 │ pve-nodeinfo-collect      │   写入   │ pvedaemon API worker         │
 │ systemd timer，每 5 秒    │ ───────► │ 读 /run/pve-nodeinfo/*.json  │
 │                           │   0644   │ （普通文件，可读）           │
 │ ├ smartctl /dev/sda -j    │          └──────────────────────────────┘
 │ └ energy_uj → 差分算瓦数  │
 └───────────────────────────┘
      │                    │
  读 /dev/sda         读 energy_uj
 root:disk 0660      root:root 0400
      └──── 两者 www-data 都无权访问 ────┘
```

常见做法有三种，本项目选了第一种：

| 做法 | 代价 | 本项目 |
|---|---|---|
| root 预采集 → 写 `0644` 缓存 | 数据最多滞后 5 秒 | ✅ 采用 |
| 给 `www-data` 配 `sudo` 白名单执行 `smartctl` | Web 用户获得执行面（可读任意盘、可发起自检） | ❌ |
| `usermod -aG disk www-data` | `www-data` 获得**所有块设备读写权限**，Web 一旦被攻破可直接读虚拟机磁盘镜像 | ❌ |
| 给 `cat` / `turbostat` 设 SUID 让 Web 用户直读 | 单个 SUID 二进制即可提升为 root 读任意文件 | ❌ |

功耗不需要额外授权的原因：`energy_uj` 虽然是 `0400 root`，但 root 采集器本来就在 `root` 域里运行，读完写一份 `0644` 的 `power.json` 即可 —— **权限面没有任何变化**。

缓存目录 `/run` 是 tmpfs，**重启后清空**，由 timer 在开机 15 秒后自动填充。这段窗口内磁盘行显示「未知」、功耗行显示「采集中...」，属预期行为。

---

## 七、使用注意事项

1. **必须强制刷新**：`Shift+F5`。否则浏览器仍用旧的 `pvemanagerlib.js`。
2. **会短暂中断 Web 管理界面**：安装/卸载都会重启 `pvedaemon` 与 `pveproxy`，期间管理页面断连数秒。
3. **PVE 升级会覆盖改动**：`/usr/share/` 下的文件不属 conffile，`apt upgrade pve-manager` 会**静默覆盖**这两个文件，改动消失且不报错。升级后重新执行 `sudo ./install.sh` 即可。
4. **升级本项目**：先 `./uninstall.sh`，再装新版。安装脚本检测到已有标记会拒绝执行，防止叠加注入。
5. **不要手工删 `/run/pve-nodeinfo`**：删了也没关系，5 秒内会重建，但这期间是「未知」。
6. **单节点场景**：改动只作用于本节点文件。集群环境需在**每台节点**分别执行。
7. **性能开销**：温度/频率为 sysfs 直读（约 10ms/次）；磁盘为每 5 秒一次 `smartctl`（约 20ms）；功耗为 3 次 sysfs 读（`name` / `energy_uj` / `max_energy_range_uj`，微秒级）。整个 `Nice=10` 且 `IOSchedulingClass=idle`。总体远低于原社区脚本（每次轮询 fork `turbostat` + `sleep 0.25`）。
8. **字段在 API 中可见**：数据通过 `/api2/json/nodes/<node>/status` 返回，任何已登录 PVE 的用户都能看到，**包含磁盘型号、序列号等 SMART 原始字段**。多用户环境请注意可见性。

---

## 八、已知问题

| 编号 | 问题 | 影响 | 处理建议 |
|---|---|---|---|
| #1 | 磁盘/功耗数据最多滞后 5 秒 | 对健康度观察无实际影响 | 需要立即刷新时执行 `sudo /usr/local/bin/pve-nodeinfo-collect` 两次（间隔 2 秒） |
| #2 | 重启后约 20 秒内磁盘行显示「未知」、功耗行显示「采集中...」 | 开机瞬间的短暂状态 | 属预期；`/run` 为 tmpfs，需等 timer 首次（及第二次）采集 |
| #3 | 功耗仅支持 Intel RAPL | AMD 平台显示「本机不支持功耗读取」 | AMD 的 `amd_energy` 走 hwmon（`energy1_input`），接口不同，尚未实现 |
| #4 | `psys` 退化的主板上不显示整机功耗 | 只有封装功耗，没有主板+CPU 的合计 | 属硬件限制。采集器已做可信性校验（`psys ≥ 封装 × 0.85` 才采纳），不会显示错误数值 |
| #5 | 封装功耗不等于整机功耗 | 不含硬盘、网卡、风扇等外围 | 需要整机功耗请看 `psys` 域；两者都不测墙插实际功率 |
| #6 | 无风扇转速 | 部分机器缺少该行 | 取决于主板是否暴露 `fan*_input`；测试机（N100）本身无该传感器 |
| #7 | 仅支持 PVE 8.x / 9.x | 旧版本无法安装 | 锚点结构不同时脚本明确报「不受支持」并退出，不会硬改 |
| #8 | 面板高度按行数估算（28px/行） | 极端情况可能留白或轻微裁切 | 调整 `scripts/patch_pve_nodes.py` 的 `LINE_HEIGHT` 后重装 |
| #9 | 升级 PVE 后改动丢失 | 需重新安装 | 见「注意事项」第 3 条 |
| #10 | `smartctl` 缺失时磁盘行显示「未知」 | 无法区分「没装工具」与「读不到盘」 | 功耗与温度/频率不受影响；装 `smartmontools` 即可 |
| #11 | 仅显示磁盘当前瞬时温度 | 无历史曲线 | 本版本不做数据持久化 |

---

## 九、目录结构

```
pve-nodeinfo-1.2.0/
├── README.md                    本文件
├── CHANGELOG.md                 版本变更记录
├── VERSION                      版本号
├── LICENSE                      MIT
├── .gitattributes               强制 LF 行尾，避免 Windows 克隆后脚本报 "bad interpreter"
├── install.sh                   安装（--dry-run、自动备份、失败回滚、缓存与权限校验）
├── uninstall.sh                 卸载（校验式还原，含 systemd 清理）
├── scripts/
│   ├── pve-hwinfo.sh            温度/频率采集器（只读 sysfs）
│   ├── pve-nodeinfo-collect     硬件采集器（root 运行，采 SMART + 功耗，写 /run/pve-nodeinfo/）
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
| `/usr/share/perl5/PVE/API2/Nodes.pm` | 修改 | 追加 3+N 个只读字段 |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | 修改 | 追加显示项 + 调整面板高度 |
| `/usr/local/bin/pve-hwinfo.sh` | 新增 | 温度/频率采集器 |
| `/usr/local/bin/pve-nodeinfo-collect` | 新增 | 磁盘 + 功耗采集器 |
| `/etc/pve-nodeinfo/disks.conf` | 新增 | 设备清单（`sd0=/dev/sda` 形式） |
| `/etc/pve-nodeinfo/VERSION` | 新增 | 已安装版本号，便于 PVE 升级后判断 |
| `/etc/systemd/system/pve-nodeinfo-collect.{service,timer}` | 新增 | 定时采集 |
| `/run/pve-nodeinfo/sdN.json` | 运行时 | SMART 缓存（tmpfs，重启清空） |
| `/run/pve-nodeinfo/power.json` | 运行时 | 功耗缓存（`{"ok":true,"pkg_w":3.97,"psys_w":null,"ts":…}`） |
| `/run/pve-nodeinfo/.power.state` | 运行时 | 上次采样的累计微焦与时间戳，用于差分 |
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
