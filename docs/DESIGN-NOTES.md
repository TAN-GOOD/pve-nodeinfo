# 设计取舍与安全审查结论

本文记录 v1.0.0 在实现方式上做的取舍，以及为什么不采用某些"更省事"的做法。

---

## 一、为什么改这两个文件

PVE 节点摘要面板的数据链是：

```
pvedaemon  →  PVE::API2::Nodes::status  →  JSON
                     ↑ 构造 $res 哈希
浏览器  →  /api2/json/nodes/<node>/status
        →  pvemanagerlib.js 的 pveNodeStatus 组件渲染 items
```

所以要让页面显示自定义数据，只能两头都动：

1. `Nodes.pm`：往 `$res` 里加字段（后端数据源）
2. `pvemanagerlib.js`：往 `pveNodeStatus` 的 `items` 数组里加显示项（前端渲染）

显示项通过 `textField` 绑定字段名，`renderer` 负责把原始值转成可读文本。这一点在 PVE 9.1.1 中经代码核实：`Proxmox.widget.InfoController.updateField()` 里

```js
} else if (field.textField !== undefined) {
    field.updateValue(renderer.call(field, me.getRecordValue(field.textField)));
}
```

即**配置了 `textField` 且自定义 `renderer` 时，renderer 收到的是字段值本身**（不是 `{data}` 对象——那是 `multiField: true` 的情形）。这是插入点能生效的前提。

---

## 二、为什么用 sysfs 而不是 lm-sensors

原本的方案是安装 `lm-sensors`，调用 `sensors -A` 解析文本。放弃它的直接原因：目标主机 `apt` 完全不可用（DNS 被劫持到 `198.18.x.x` 伪造段，TCP 出网失败）。

但这反而暴露了更好的做法——内核本来就把温度暴露在 sysfs 里：

```
/sys/class/hwmon/hwmon1/name           → coretemp
/sys/class/hwmon/hwmon1/temp1_label    → Package id 0
/sys/class/hwmon/hwmon1/temp1_input    → 46000  (毫摄氏度)
```

好处：
- **零依赖**，不需要装包，不占磁盘，不受软件源可用性影响
- **无文本解析**，不用正则去啃 `sensors` 的多行格式（原脚本的解析相当脆弱，遇到不同芯片就乱）
- **更快**，单次读取约 10ms

`lm-sensors` 的价值在于给不规范的传感器命名、以及处理 `sensors-detect` 的复杂加载逻辑。对温度显示这种需求，sysfs 足够。

---

## 三、为什么坚决不设 SUID

原社区脚本有三个 `chmod +s`：

```bash
chmod +s /usr/sbin/smartctl
chmod +s /usr/sbin/hdparm
chmod +s /usr/sbin/turbostat
```

这是**为了"让非 root 也能跑"**——但本项目根本不需要：注入的 Perl 代码在 `pvedaemon` 进程内执行，而 `pvedaemon` 本身就是 root。也就是说，SUID 在这里是纯粹的多余。

多余的代价不小：
- `hdparm` 带 SUID 后，任何本地用户都能对磁盘下发 ATA 指令（包括 `--security-erase`）
- `smartctl` 带 SUID 后可以读所有磁盘的原始数据
- `turbostat` 带 SUID 后可读写 MSR 寄存器，配合 `msr` 模块可造成主机崩溃

即使默认只有 root 能登录，这也是无谓的攻击面。**v1.0.0 一处都不设。**

---

## 四、为什么不改 proxmoxlib.js

原脚本还会顺手去掉"无有效订阅"弹窗。本项目**完全跳过**这一步，原因有三：

1. **与功能无关**。本项目的目标是显示硬件信息，订阅提示是另一件事，混在一起会让改动范围不可控。
2. **锚点已经变了**。实测 PVE 9.1.1 中该处代码已从 `if (...) { Ext.Msg.show(...) }` 改为 `void({ //Ext.Msg.show({` 形式，原脚本的多行 `sed -E`（`H`/`x`/`d` 组合）依赖旧形态，硬套会得到不可预测的改写结果——而这是 818KB 的前端主包，改坏了整个管理界面白屏。
3. **回滚基线不干净**。若该文件此前已被别的脚本改过（本次目标主机就是这种情况，`dpkg --verify` 报 `??5??????`），备份出来的 `.bak` 也不是官方原版，出问题时回不到干净状态。

---

## 五、中文标签的编码问题

第一版实现直接让采集脚本输出中文标签（`主板: 27.8`），结果页面显示 `ä¸»æ¿: 27.8`。

实测取证：

```
采集脚本输出原始字节:  e4 b8 bb e6 9d bf   ← 正确的 UTF-8 "主板"
API 返回的字节:        c3 a4 c2 b8 c2 bb   ← 被编码了两次
Perl 侧验证: 反引号取回的是裸字节，未打 utf8 标志
             JSON::XS->utf8->encode 会把每个字节当成一个字符再编一次
```

修复方式不是在 Perl 里加 `Encode::decode`（那样要改注入代码，风险更高），而是**让采集端只输出 ASCII 标签，中文映射交给前端 JS**——JS 文件本身是 UTF-8，浏览器按 `charset=utf-8` 解析，不存在这个问题。

---

## 六、注入量与失败策略

注入 `Nodes.pm` 的代码越少越好，因为那是 PVE 的核心 Perl 模块，改坏了 `pvedaemon` 起不来，整个 Web 界面都没了。

v1.0.0 只注入 3+N 行，逻辑全部外置到 `/usr/local/bin/pve-hwinfo.sh`：

```perl
#pve-nodeinfo
$res->{thermalstate} = `/usr/local/bin/pve-hwinfo.sh thermal 2>/dev/null`;
$res->{cpuFreq} = `/usr/local/bin/pve-hwinfo.sh cpu 2>/dev/null`;
$res->{sd0} = `
if [ -b /dev/sda ]; then /usr/sbin/smartctl /dev/sda -a -j 2>/dev/null; else echo '{}'; fi
`;
```

附带的好处：注入部分不含 `$` 变量转义（原脚本因为用引号 heredoc，塞满了 `\$`），出错概率大幅降低；采集逻辑要改时直接改 shell 脚本，不用碰 PVE 文件。

失败策略分三层：

| 层级 | 机制 |
|---|---|
| 补丁前 | 锚点断言，数量不符立即退出，不盲改 |
| 补丁后 | `perl -c` 语法自检，失败自动还原并重启服务 |
| 前端 | `node --check` 语法验证 + 所有 renderer 包 `try/catch`，取值异常时显示占位文案而非报错 |

---

## 七、安全审查结论（针对本次实现）

| 检查项 | 结论 |
|---|---|
| 网络访问 | 无。安装与运行均不联网 |
| 敏感信息外发 | 无。不读密钥、不读 `/etc/pve` 凭据、无回传 |
| SUID / 权限提升 | 无。不修改任何二进制权限位 |
| 破坏性操作 | 无删除类操作。仅原地改写 2 个文件，且有 tar + sha256 备份 |
| 临时文件 | 无 `/tmp` 固定路径写入（补丁器用 `*.pve-nodeinfo.tmp` + `os.replace` 原子替换） |
| 注入风险 | 注入内容为常量字符串 + 固定路径，不含用户输入拼接 |
| 数据可见性 | 温度/磁盘信息通过已认证的 PVE API 返回，与页面一致；多用户环境需注意 SMART 含序列号 |
| 可回滚性 | 卸载脚本 `sha256sum -c` 校验还原结果，实测与安装前逐字节一致 |
