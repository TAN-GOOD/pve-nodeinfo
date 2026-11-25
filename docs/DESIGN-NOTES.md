# 设计取舍与安全审查结论

本文记录 v1.0.0 / v1.1.0 在实现方式上做的取舍，以及为什么不采用某些"更省事"的做法。

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

这是**为了"让非 root 也能跑"**——但本项目根本不需要：

- 温度/频率读的是 `sysfs`，本来就是全局可读，不需要任何特权；
- 磁盘 SMART 由 systemd 以 root 身份预采集（见第四节），也不需要非 root 去碰块设备。

多余的代价不小：
- `hdparm` 带 SUID 后，任何本地用户都能对磁盘下发 ATA 指令（包括 `--security-erase`）
- `smartctl` 带 SUID 后可以读所有磁盘的原始数据
- `turbostat` 带 SUID 后可读写 MSR 寄存器，配合 `msr` 模块可造成主机崩溃

即使默认只有 root 能登录，这也是无谓的攻击面。**本项目一处都不设。**

> 附注（v1.1.0 修正）：v1.0.0 这里原本写的是"注入的 Perl 代码在 `pvedaemon` 进程内执行，而 `pvedaemon` 本身就是 root"。这句话只对了一半——主进程是 root，但**处理 API 请求的 worker 会降权为 `www-data`**，正是这个误判导致了磁盘行的误报。结论（不设 SUID）依然成立，但理由要改：真正需要特权的部分已收敛到 root 域的定时采集里。

---

## 四、v1.1.0：磁盘数据的权限陷阱

这是 v1.0.0 发布后才暴露出来的问题，也是本版本存在的原因，值得完整记录。

### 现象

面板磁盘行显示 **「找不到硬盘，可能已直通或被卸载」**，但硬盘完全正常。

### 排查过程

| 步骤 | 观测 | 结论 |
|---|---|---|
| 1 | `smartctl /dev/sda -a -j` 手工执行，`rc=0`，型号齐全 | 硬盘没坏 |
| 2 | `pvesh get /nodes/localhost/status` 里 `sd0` 有 17902 字节、`model_name` 正常 | 后端数据没问题 |
| 3 | 同一个 API，走 Web（`GET /nodes/<node>/status`，即使登录 root@pam）只返回 **592 字节** | 差异在网络层而不是渲染层 |
| 4 | 592 字节内容：`message: "Smartctl open device: /dev/sda failed: Permission denied"` | **权限问题** |
| 5 | `ls -l /dev/sda` → `brw-rw---- root disk`；`id www-data` → `uid=33 gid=33` | www-data 既不是 root 也不在 disk 组 |
| 6 | 连续 30 次采样 `model_name` 一次不缺 | 不是间歇性故障，是稳定被拒绝 |

### 根因

`pvedaemon` 主进程是 root，但**处理 API 请求的 worker 会降权成 `www-data`**（`pveproxy` 本身就是 www-data）。Perl 里的 `$res->{sd0}` 由 worker 执行，于是 `smartctl` 读不到 `/dev/sda`。

`smartctl` 拿不到设备时不会报错退出（退出码仍可能为 0），而是输出一个**只含 `messages` 数组、没有 `model_name`** 的 JSON。旧渲染器看到没有型号，就输出了「找不到硬盘，可能已直通或被卸载」——**把权限问题误诊成了硬件问题**，这类误导性文案比直接报错更麻烦。

### 三种修法及取舍

| 方案 | 改动 | 权限代价 |
|---|---|---|
| **root 预采集 → `0644` 缓存**（采用） | 新增 1 个 shell + 2 个 unit + 1 个配置文件 | **零**。没有任何账户、组、SUID 变化 |
| `sudo` 白名单给 www-data 执行 `smartctl` | 1 个 sudoers 文件 | Web 用户获得执行面：可读任意盘 SMART、可发起自检（`-t`） |
| `usermod -aG disk www-data` | 1 条命令 | 最大：www-data 获得**所有块设备读写权限**，Web 一旦被攻破可直接读写虚拟机磁盘镜像 |

选择第一种的理由：它把"需要特权"这件事收敛到 root 域内部，`www-data` 域拿到的是一个普通只读文件——与它读 `/var/log` 没有区别。代价只是数据最多滞后 5 秒。

### 实现要点

- `/run` 是 tmpfs，缓存重启即清空，不需要清理逻辑；timer 在开机 15 秒后自动填充。
- 采集器写临时文件再 `mv`（同目录，原子），避免面板读到半个 JSON。
- **采集失败时保留上一次的有效数据**，只在设备真的不存在（`! -b`）时才写 `{}`。否则偶发的 `smartctl` 超时会让面板在「正常」和「未检测到」之间跳变。
- 缓存文件 `0644`，目录 `0755`，`www-data` 可读——安装脚本会**以 `www-data` 身份实际 `test -r` 验证一次**，不通过就回滚。

---

## 五、为什么不改 proxmoxlib.js

原脚本还会顺手去掉"无有效订阅"弹窗。本项目**完全跳过**这一步，原因有三：

1. **与功能无关**。本项目的目标是显示硬件信息，订阅提示是另一件事，混在一起会让改动范围不可控。
2. **锚点已经变了**。实测 PVE 9.1.1 中该处代码已从 `if (...) { Ext.Msg.show(...) }` 改为 `void({ //Ext.Msg.show({` 形式，原脚本的多行 `sed -E`（`H`/`x`/`d` 组合）依赖旧形态，硬套会得到不可预测的改写结果——而这是 818KB 的前端主包，改坏了整个管理界面白屏。
3. **回滚基线不干净**。若该文件此前已被别的脚本改过（本次目标主机就是这种情况，`dpkg --verify` 报 `??5??????`），备份出来的 `.bak` 也不是官方原版，出问题时回不到干净状态。

---

## 六、中文标签的编码问题

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

## 七、注入量与失败策略

注入 `Nodes.pm` 的代码越少越好，因为那是 PVE 的核心 Perl 模块，改坏了 `pvedaemon` 起不来，整个 Web 界面都没了。

v1.1.0 注入 2+N 个字段，**全部逻辑外置**：温度/频率调 `pve-hwinfo.sh`，磁盘只读缓存文件。

```perl
#pve-nodeinfo
$res->{thermalstate} = `/usr/local/bin/pve-hwinfo.sh thermal 2>/dev/null`;
$res->{cpuFreq} = `/usr/local/bin/pve-hwinfo.sh cpu 2>/dev/null`;
$res->{sd0} = do {
    my $f = '/run/pve-nodeinfo/sd0.json';
    my $c = '';
    if (open(my $fh, '<', $f)) { local $/; $c = <$fh>; close($fh); }
    $c // '';
};
```

把"执行外部命令"换成"读文件"之后，注入代码不再依赖 shell、不再有路径含空格的隐患，也不需要判断设备是否存在——那些判断都在采集器里。

附带的好处：注入部分不含 `$` 变量转义（原脚本因为用引号 heredoc，塞满了 `\$`），出错概率大幅降低；采集逻辑要改时直接改 shell 脚本，不用碰 PVE 文件。

失败策略分三层：

| 层级 | 机制 |
|---|---|
| 补丁前 | 锚点断言，数量不符立即退出，不盲改 |
| 补丁后 | `perl -c` 语法自检，失败自动还原并重启服务 |
| 安装时 | 采集缓存内容校验 + 以 `www-data` 身份实测读权限，失败自动回滚 |
| 前端 | `node --check` 语法验证 + 所有 renderer 包 `try/catch`，取值异常时显示占位文案而非报错 |

---

## 八、安全审查结论（针对本次实现）

| 检查项 | 结论 |
|---|---|
| 网络访问 | 无。安装与运行均不联网 |
| 敏感信息外发 | 无。不读密钥、不读 `/etc/pve` 凭据、无回传 |
| SUID / 权限提升 | 无。不修改任何二进制权限位 |
| 账户与组 | 无。不改 `/etc/sudoers*`、不改用户组关系（v1.1.0 的权限问题用缓存文件解决，而非提权） |
| 破坏性操作 | 无删除类操作。仅原地改写 2 个文件，且有 tar + sha256 备份 |
| 临时文件 | 无 `/tmp` 固定路径写入（补丁器用 `*.pve-nodeinfo.tmp` + `os.replace` 原子替换；缓存写在 `/run/pve-nodeinfo/`，属主 root、权限 0644） |
| 注入风险 | 注入内容为常量字符串 + 固定路径，不含用户输入拼接 |
| 数据可见性 | 温度/磁盘信息通过已认证的 PVE API 返回，与页面一致；多用户环境需注意 SMART 含序列号 |
| 可回滚性 | 卸载脚本 `sha256sum -c` 校验还原结果，实测与安装前逐字节一致 |
