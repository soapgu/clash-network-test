# clash-network-test

诊断 Clash 配置中的多 IP 域名入口，并在确认后将节点锁定到稳定 IP。

项目提供两套完全独立的工具：

- <img src="https://upload.wikimedia.org/wikipedia/commons/d/d7/Android_robot.svg" alt="Android 机器人 Logo" width="20"> **Android / Clash for Android（CFA）**：使用 `cfa-entry-ip.sh` 读取手机导出的 YAML，在电脑上生成锁定 IP 的新 YAML；
- <img src="https://upload.wikimedia.org/wikipedia/commons/8/8a/Apple_Logo.svg" alt="Apple Logo" width="18"> **macOS / Clash Verge Rev**：使用 `clash-entry-ip.sh` 直接诊断和修改 Mac 上的当前订阅。

> 请先确认自己的平台和客户端，再选择对应脚本。两个脚本的输入和应用方式不同，不能混用。

---

<img src="https://upload.wikimedia.org/wikipedia/commons/d/d7/Android_robot.svg" alt="Android 机器人 Logo" width="72">

## Android — Clash for Android（CFA）

> **适用平台：Android 手机。** 脚本在电脑上处理手机 CFA 导出的配置，不会连接或修改手机，也不要对它使用 macOS 的 `clash-entry-ip.sh`。

### 使用手机导出的 YAML 生成锁定版 YAML

先在手机 CFA 中导出当前配置，将导出的 YAML 传到电脑。`.yaml`、`.yml`、
`.yaml.txt` 和 `.yml.txt` 都可以直接作为输入。文件路径包含中文或空格时必须加引号：

```bash
./cfa-entry-ip.sh diagnose "/路径/手机 导出的配置.yaml.txt"
```

脚本会容错识别 CFA 常见的行内及块状节点，不要求导出文件能通过严格 YAML
解析。诊断方法与 Clash Verge 版本相同：排除官网、剩余流量、套餐时间等展示
节点，发现唯一真实入口域名的候选 IPv4，并抽样节点端口进行多轮 TCP 测试。

以下配置会在诊断阶段说明原因并跳过，不会进入可应用状态：

- 已经直接使用固定 IP；
- 使用多个 IP、多个真实入口域名，或域名和 IP 混合；
- 唯一入口域名只解析到一个 IPv4；
- 入口仅支持 IPv6 或没有有效 IPv4。

查看报告后，应用一个通过全部测试的 IP：

```bash
./cfa-entry-ip.sh apply 198.51.100.20
```

脚本不会修改 CFA 导出的源文件，而是在项目的 `outputs/` 目录生成：

```text
原文件名-locked-198.51.100.20-生成时间.yaml
```

生成时只替换 `proxies` 区域内目标入口的 `server`，节点端口、密码、协议参数、
代理组和规则均保持不变。完成后把这个新 YAML 传回手机，并手动导入 CFA。

查看最近诊断和生成状态：

```bash
./cfa-entry-ip.sh status
```

`status` 只能确认电脑上的报告、源文件和输出文件状态，无法判断手机 CFA 是否
已经导入或启用。CFA 脚本不需要 `rollback`，因为源文件从未被修改；需要回退
时，重新导入原始配置即可。

锁定版是本地配置副本，不会自动跟随远程订阅更新。订阅更新后需要重新执行：
手机导出、电脑诊断、生成锁定 YAML、传回手机并导入。

导出文件和 `outputs/` 中包含节点密码等敏感信息，不要上传到公开位置，也不要
提交到 Git 仓库。`outputs/`、检测报告和状态文件均已加入 `.gitignore`。

可通过独立的 `CFA_ENTRY_*` 环境变量调整测试参数，例如：

```bash
CFA_ENTRY_TEST_ROUNDS=2 CFA_ENTRY_SAMPLE_PORTS=2 \
  ./cfa-entry-ip.sh diagnose "/路径/配置.yaml"
```

---

<img src="https://upload.wikimedia.org/wikipedia/commons/8/8a/Apple_Logo.svg" alt="Apple Logo" width="64">

## macOS — Clash Verge Rev

> **适用平台：macOS。** 脚本直接操作 Mac 上 Clash Verge Rev 的当前订阅，不适用于 Android 手机导出的 YAML。

深入了解：[clash-entry-ip.sh 工作原理](CLASH_ENTRY_IP.md)。

### 自动诊断与锁定

先在 Clash Verge中选择需要诊断的订阅，再执行：

```bash
./clash-entry-ip.sh diagnose
```

脚本会从 `profiles.yaml.current` 定位当前订阅，自动识别真实代理节点使用的
入口域名，再查询系统 DNS、Mihomo使用的 DNS和权威 DNS。它最多抽取12个
代表端口；如果存在 `9051` 会强制纳入。每个候选 IP和端口测试5次，只有
全部成功的 IP才允许应用。检测结束会打印推荐 IP、可用备选和不可用 IP。

以下情况会说明原因并跳过，不修改任何配置：

- 订阅已经直接使用一个固定 IP；
- 订阅使用多个 IP、域名和 IP混合，或包含多个真实入口域名；
- 唯一入口域名只解析到一个 IPv4；
- 入口仅支持 IPv6或没有有效 IPv4。

官网、剩余流量、套餐时间等明显的信息展示节点不会参与入口判断。

查看报告后，明确应用一个合格 IP：

```bash
./clash-entry-ip.sh apply 198.51.100.20
```

应用操作会：

1. 备份当前订阅的脚本覆写及当前运行配置；
2. 只在当前订阅的脚本覆写中把自动识别的入口域名固定为指定 IP；
3. 通过 Mihomo控制接口立即重新加载配置；
4. 通过本地代理发起请求，确认重载后的代理可用；
5. 任一步骤失败时恢复备份。

查看状态、恢复订阅原始入口或撤销最近一次变更：

```bash
./clash-entry-ip.sh status
./clash-entry-ip.sh reset
./clash-entry-ip.sh rollback
```

`reset` 会移除本工具写入当前订阅的入口锁定，并把当前运行配置中的锁定 IP
恢复为订阅原始域名。它不会用旧快照覆盖整个配置，因此锁定期间的订阅更新会
保留。当前订阅未被本工具锁定时，`reset` 会提示无需恢复并安全退出。

`rollback` 用于撤销最近一次成功变更，包括 `apply` 或 `reset`；因此在执行
`reset` 后仍可通过 `rollback` 回到恢复前的锁定状态。

检测报告保存在 `reports/`，运行状态保存在 `.state/`。两者均已加入
`.gitignore`。报告记录订阅 UID、原始文件指纹、域名及测试端口，默认30分钟
内有效。切换或更新订阅后旧报告不能用于应用。

可通过环境变量缩短测试，用于开发验证：

```bash
CLASH_ENTRY_TEST_ROUNDS=2 CLASH_ENTRY_SAMPLE_PORTS=2 \
  ./clash-entry-ip.sh diagnose
```

## 单入口持续观察

`check-proxy-port.sh` 用于持续检测单个 TCP入口，不会修改 Clash配置。

指定需要观察的目标：

```bash
./check-proxy-port.sh 198.51.100.20
```

指定 IP、端口和检测间隔（秒）：

```bash
./check-proxy-port.sh 198.51.100.20 9051 1
```

按 `Ctrl+C` 停止检测。

## 图标来源

- Android 机器人图标来自 [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Android_robot.svg)，作者为 Google Inc.，按 CC BY 3.0 使用；
- Apple Logo 来自 [Wikimedia Commons](https://commons.wikimedia.org/wiki/File:Apple_Logo.svg)，仅用于标识适用平台。
