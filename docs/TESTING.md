# 测试与验证记录

本文记录 v1.0.0 在真机上的验证过程与结果。所有数据来自实际执行，非模拟。

---

## 一、测试环境

| 项目 | 值 |
|---|---|
| Proxmox VE | 9.1.1（`pve-manager/9.1.1`） |
| 操作系统 | Debian GNU/Linux 13 (trixie) |
| 内核 | 6.17.2-1-pve |
| CPU | Intel N100（4 核，无风扇传感器） |
| 磁盘 | 1 块 SATA SSD（119GB） |
| python3 | 3.13.5 |
| perl | 5.40.1 |
| smartctl | 7.4 r5620 |
| 集群 | 单节点（无 corosync 配置） |
| 外网 | **不可用**（DNS 被劫持至保留段，TCP 出网失败） |

最后一条很关键：它使"装 `lm-sensors`"的方案直接不可行，也顺带验证了本版本**完全不依赖网络**这一特性。

---

## 二、前置结构核验

在动手前先确认 PVE 9.1.1 上三个锚点是否仍成立，避免盲改：

| 锚点 | 期望 | 实测 | 结论 |
|---|---|---|---|
| `Nodes.pm` 中 `PVE::pvecfg::version_text()` | 位于构造 `$res` 的 status 子程序内 | 第 534 行，处于 `my $res = {`（493 行）的哈希构造中 | 有效 |
| `pvemanagerlib.js` 中 `textField: 'pveversion'` | 其后 3 行内有 `},`，再下一行为 `],` | 48834 / 48836 / 48837 行，完全吻合 | 有效 |
| `widget.pveNodeStatus` 的 `height:` | 在 alias 后 8 行内 | 48699 alias → 48701 `height: 350` | 有效 |
| `nodeStatus: nodeStatus` 的 `minHeight:` | 在 15 行内 | 49219 → 49227 `minHeight: 360` | 有效 |
| `proxmoxlib.js` 订阅检查块 | `if (...) { Ext.Msg.show }` | **已变为 `void({ //Ext.Msg.show({`** | 失效（故不改此文件） |

另外核实了渲染器签名，这是插入项能否生效的前提。`proxmoxlib.js` 中：

```js
} else if (field.textField !== undefined) {
    field.updateValue(renderer.call(field, me.getRecordValue(field.textField)));
}
```

即配置 `textField` + 自定义 `renderer` 时，renderer 收到的是**字段值**；只有 `multiField: true` 才收到整条记录。本项目的显示项均不设 `multiField`，因此按值渲染成立。

---

## 三、安装测试（发布包实测）

用发布包内的 `install.sh` 完整执行：

| 步骤 | 结果 |
|---|---|
| 环境检查 | 通过，识别 PVE 9.1.1 / python3 3.13.5 |
| 磁盘检测 | 识别 1 块：`/dev/sda  固态  119GB  Great Wall GW560` |
| 备份 | 生成 `/root/pve-nodeinfo-backup-<时间戳>/`，含 tar + sha256 |
| 部署采集器 | `/usr/local/bin/pve-hwinfo.sh` 0755 root:root |
| 采集自检 | 输出 `Board: 27.8 / CPU Package: 55.0 / CPU0~3: 54~55` |
| 打补丁 | Nodes.pm 注入 3 字段；JS 插入 3 项；`height 350→434`、`minHeight 360→444` |
| `perl -c` | syntax OK |
| 重启服务 | pvedaemon / pveproxy 均 active |
| API 验证 | `thermalstate`、`cpuFreq` 均正常返回 |
| `--check` | 三项均报「已安装」，退出码 0 |
| 重复安装保护 | 二次执行被拒绝并提示先卸载 |

---

## 四、前端渲染验证

不依赖浏览器，用 Node 直接跑注入的**真实代码**（从补丁后的 `pvemanagerlib.js` 中切出），喂真实 API 数据：

```
[thermal] 温度(°C)
   -> 主板: 28°C | CPU封装: 61°C | CPU0: 60°C | CPU1: 61°C | CPU2: 61°C | CPU3: 61°C
[cpumhz] CPU频率(GHz)
   -> 3.0 | 2.9 | 3.0 | 3.0 | MAX: 3.4 | MIN: 0.7 | 调速器: PERFORMANCE
[disk0] 固态硬盘0
   -> Great Wall GW560 128GB | 温度: 30°C | 通电: 1306时,次: 9 | SMART: 正常
```

### 边界测试

对每个 renderer 依次喂 `undefined` / `''` / `null` / `'garbage'` / `'{"a":1}'`：

```
✅ 全部渲染通过（无 throw，无 undefined 返回）
```

这一项是为防「某个字段取不到值导致整个摘要面板渲染中断」。所有 renderer 均包了 `try/catch` 兜底。

### 语法门禁

```bash
node --check pvemanagerlib.js   # 2.18MB 全文
→ 通过，无解析错误
```

改前端主包最怕语法错误导致整站白屏，因此这一步是**发布前的必过关卡**，而不是可选项。

---

## 五、卸载测试

| 检查项 | 结果 |
|---|---|
| 自动定位最近备份 | 正确 |
| 还原后 sha256 校验 | `Nodes.pm: OK`、`pvemanagerlib.js: OK`（与安装前逐字节一致） |
| 标记残留 | 0 |
| 采集脚本 | 已删除 |
| 面板高度 | 已复原为 `height: 350` |
| API 字段 | `thermalstate` 已消失 |
| 服务状态 | pvedaemon / pveproxy 均 active |

卸载后**再次安装**，流程同样通过，说明安装/卸载可反复循环，不会累积脏状态。

---

## 六、性能

| 操作 | 实测耗时 |
|---|---|
| `pve-hwinfo.sh thermal` + `cpu` 各一次 | 约 0.02s（合计） |
| `smartctl /dev/sda -a -j` | 约 0.02s |
| 完整 `pvesh get /nodes/localhost/status` | 约 0.93s（含 pvesh 自身启动开销） |

作为对比，常见社区脚本在每次状态轮询时会 fork `turbostat` 并 `sleep 0.25`，单次即固定增加 250ms 以上，且随浏览器标签页数量线性叠加。本版本改为纯 sysfs 读取，无 sleep、无额外进程。

内存占用无变化（与安装前同一水位）。

---

## 七、编码问题回归

第一版实现曾出现中文乱码，已修复并留作回归项：

| 检查点 | 修复前 | 修复后 |
|---|---|---|
| 采集脚本输出字节 | `e4 b8 bb e6 9d bf`（正确 UTF-8） | 同（改用 ASCII 标签 `Board`） |
| API 返回字节 | `c3 a4 c2 b8 c2 bb`（二次编码） | 纯 ASCII，无编码风险 |
| 页面显示 | `ä¸»æ¿: 27.8` | `主板: 28°C` |

根因：Perl 通过反引号取回的是**裸字节**，未打 utf8 标志，`JSON::XS->utf8->encode` 会把每个字节当成一个字符再编码一次。修复策略是把中文映射移到前端 JS（文件本身是 UTF-8，浏览器按 `charset=utf-8` 解析）。

---

## 八、未覆盖项

| 项 | 原因 | 影响 |
|---|---|---|
| 多磁盘场景 | 测试机仅 1 块盘 | 代码按 `/sys/block` 循环生成，逻辑上支持多块，但未实测 |
| NVMe 设备 | 测试机无 NVMe | 采集走 `smartctl -a -j`，与 SATA 同路径，预期一致 |
| PVE 8.x | 无环境 | 锚点结构在 8.x 与 9.x 接近，但未实测 |
| 浏览器实际观感 | 无图形化浏览器环境 | 已用 `node --check` + 真实数据渲染替代；面板高度按 28px/行估算，极端情况可能留白 |
| 集群环境 | 单节点 | 需在每台节点分别执行 |

以上均建议在正式推广前补充验证。
