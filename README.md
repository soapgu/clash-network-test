# clash-network-test

诊断 Clash Verge当前订阅的多 IP域名入口，并在确认后将节点锁定到稳定 IP。

## 自动诊断与锁定

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

查看状态或回滚：

```bash
./clash-entry-ip.sh status
./clash-entry-ip.sh rollback
```

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
