# 变更记录

本项目遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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
