# 变更记录

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.1.0] - 2026-11-26

### 修复

- **磁盘行误报「找不到硬盘，可能已直通或被卸载」**（v1.0.0 的主要缺陷）。
  根因是 PVE 的 API worker 会降权为 `www-data`，而 `/dev/sdX` 权限为 `brw-rw---- root:disk`，`smartctl` 读不到设备、只返回 `Permission denied`，输出的 JSON 里没有 `model_name`；旧渲染器把「没有型号」直接判定为「硬盘不存在」，给出了完全错误的结论。
- 渲染器不再把「没有型号」等同于「硬盘不存在」，改为区分四种场景：
  `未知`（缓存未就绪）/ `未检测到该磁盘` / `无法读取 SMART（权限不足）` / `读取失败: <smartctl 原始信息>`。
- 采集失败时不再用空结果覆盖上一次的有效数据，避免面板在「正常」与「未检测到」之间跳变。
- 磁盘渲染器先处理空值再 `JSON.parse`，缓存文件暂时为空时不再落到「无法获得有效数据」。

### 变更

- 磁盘数据获取方式由「每次 API 请求执行 `smartctl`」改为 **root 预采集 + 面板只读缓存**：
  新增 systemd timer 每 5 秒以 root 运行采集器，结果写入 `/run/pve-nodeinfo/sdN.json`（`0644`），
  API 侧只读普通文件。**不配 sudo、不加 `disk` 组、不设 SUID**，权限面零变更。
- `Nodes.pm` 中磁盘字段由反引号执行 `smartctl` 改为读取缓存文件。
- 顺带降低开销：不再随每个浏览器标签页的轮询 fork `smartctl`（单次约 18KB JSON）。
- `patch_pve_nodes.py` 新增生成 `/etc/pve-nodeinfo/disks.conf`；`--check` 扩展为同时检查两个采集器、设备清单、systemd 单元与缓存目录。
- `install.sh` 增加 systemd 单元安装、缓存内容校验、**`www-data` 读权限校验**（失败即回滚），回滚流程覆盖单元与配置清理。
- `uninstall.sh` 先停 timer 再还原文件，避免删掉缓存目录后被下一轮采集重建。
- `README` 新增「工作原理与权限模型」章节，说明三种可选方案及本项目的取舍。

### 新增文件

- `scripts/pve-nodeinfo-collect`：SMART 采集器，读 `/etc/pve-nodeinfo/disks.conf`，写 `/run/pve-nodeinfo/`。
- `systemd/pve-nodeinfo-collect.service`、`systemd/pve-nodeinfo-collect.timer`。

### 升级说明

- v1.0.0 → v1.1.0 必须：`sudo ./uninstall.sh`，再 `sudo ./install.sh`。安装脚本检测到已有标记会拒绝执行，防止叠加注入。

## [1.0.0] - 2026-11-26

首个发布版本。

### 新增

- 节点「摘要」面板新增三行信息：**CPU 温度**、**CPU 频率**、**磁盘健康**。
- `scripts/pve-hwinfo.sh`：只读采集器，直接读取 `/sys/class/hwmon/*` 与 `/sys/class/cpufreq/*`，**不依赖 `lm-sensors`**。
- `scripts/patch_pve_nodes.py`：带锚点断言的补丁器，支持 `--dry-run`（预演）与 `--check`（状态检查）。
- 安装时自动扫描 `/sys/block`，识别全部 `sd*` / `nvme*n*` / `vd*` 磁盘，按 `rotational` 标注固态/机械，并跳过可移动介质。
- `install.sh`：环境检查 → 自动备份（tar + sha256）→ 部署采集器 → 打补丁 → `perl -c` 语法自检 → 重启服务 → API 验证；任一步失败自动回滚。
- `uninstall.sh`：从最近备份还原，并用 `sha256sum -c` 校验是否与安装前完全一致。

### 与常见社区脚本的差异

- **不安装任何软件包**，不需要联网。
- **不设置任何 SUID 位**（原脚本会对 `smartctl` / `hdparm` / `turbostat` 执行 `chmod +s`）。注入的代码本身运行在 `pvedaemon`（root）上下文，SUID 属多余且扩大攻击面。
- **不修改 `proxmoxlib.js`**（订阅提示相关文件）。
- **不写 `/tmp` 固定路径临时文件**，消除本地符号链接覆盖风险。
- **不加载 `msr` 模块**、不写 `/etc/modules-load.d/`。
- 每次轮询不再 fork `turbostat` + `sleep 0.25`，改为纯 sysfs 读取，开销从数百毫秒降至约 10ms。
- 修正中文标签的二次编码问题：Perl 通过反引号取回的是裸 UTF-8 字节，经 `JSON::XS->utf8->encode` 会再编码一次（`e4b8bb` → `c3a4c2b8c2bb`）。本版本采集端输出 ASCII 标签，中文映射放在前端 JS 完成。

### 已知限制

- 不显示整包功耗（需 `linux-cpupower` + `msr`）。
- 仅支持 PVE 8.x / 9.x，更早版本的锚点结构不同。
- PVE 升级会覆盖 `/usr/share/` 下的改动，需重新安装。
