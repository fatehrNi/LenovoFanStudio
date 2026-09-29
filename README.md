# 拯救者 Y9000P 2022 · 风扇转速管理系统

[![test](https://github.com/fatehrNi/LenoveFanStudio/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/fatehrNi/LenoveFanStudio/actions/workflows/test.yml)

仓库：<https://github.com/fatehrNi/LenoveFanStudio>（公开）。上面的 CI 只跑**不碰硬件**的那部分
（编码门禁 / 语法 / 离线逻辑单测 / 编译打包 / 产物无头自检）；EC 相关的端到端验证必须在真的拯救者上跑，
见「完整验证.cmd」或 `tools\final_verify.ps1`。

**Legion Fan Studio** —— 绕过 Windows 电源计划，直接在 **EC（嵌入式控制器）层**调节风扇转速，
并可在 EC 层覆盖 CPU 功耗墙。零依赖：只需 Windows 自带的 PowerShell 与 .NET Framework，
**不需要** Vantage / Legion Toolkit，也不需要第三方驱动或联网。

适用机型：Lenovo Legion Y9000P 2022（机型代码 **82RF**，`LEGION_Y9000P_IAH7H`，i7-12700H + RTX 3060）。
原理对 2020+ 带 GameZone / Lfc 固件 WMI 接口的拯救者同样适用，但曲线数值按本机实测标定。

> 非官方第三方工具，与联想公司无关。操作 EC 会影响散热，请先读 [docs/实测记录.md](docs/实测记录.md)。

---

## 30 秒上手

三种入口，随你选：

| 入口 | 说明 |
|---|---|
| **LegionFanStudio.exe** | 原生托盘程序（推荐）。**没有主窗口**：启动后驻留任务栏右侧托盘（可能被 `^` 折叠起来），右键菜单：档位、满速、暂停接管、恢复正常、功耗墙预设、开机自启、状态窗口 |
| **风扇托盘.cmd** | 双击启动上面的托盘程序（自动找根目录或最新 `dist\` 里的 exe） |
| **风扇面板.cmd** | 浏览器调参面板 `http://127.0.0.1:4765/`：实时曲线图 + 8 点曲线编辑 + 安全阈值 |
| **风扇控制.cmd** | 中文命令行菜单，不需要记参数 |
| **启动守护进程.cmd / 重启守护进程.cmd** | 真正接管风扇的那个进程（要一次管理员授权）。改了代码或配置后用「重启」 |
| **完整验证.cmd** | 一整套验收：离线单测 → 硬件端到端 → 安装/卸载往返 → 打包产物链路。会故意动风扇，跑完自动恢复正常值 |

exe 在哪：`build\build.ps1` 之后有**两份**——`dist\LegionFanStudio-v1.0.0\LegionFanStudio.exe`（可分发的那份）
和仓库根目录 `LegionFanStudio.exe`（build 自动镜像过来的一份，`.gitignore` 已忽略）。
根目录那份才是这台机器该用的：托盘程序按自己所在目录找数据目录，放在 `dist\` 里它会用
`dist\...\config|logs|state`，于是显示「未托管」，而实际在跑的守护进程用的是仓库根目录那份数据。
`install.ps1` 会把开始菜单（加 `-DesktopShortcut` 还有桌面）快捷方式指向正确的那份。

命令行等价写法：

```powershell
cd E:\vibecoding\qoder\fans
powershell -ExecutionPolicy Bypass -File src\fanctl.ps1 daemon start -Profile performance   # 接管风扇（需管理员）
powershell -ExecutionPolicy Bypass -File src\fanctl.ps1 status
.\dist\LegionFanStudio-v1.0.0\LegionFanStudio.exe --status        # 一行状态，脚本可用
```

### 打包成可分发的软件

```powershell
powershell -ExecutionPolicy Bypass -File build\build.ps1        # 编译 + 组装 dist\ + 打 zip + 输出 SHA256
dist\LegionFanStudio-v1.0.0\selftest.cmd                       # 无头自检（不改动风扇）
```

产物是可移植目录：把 `dist\LegionFanStudio-vX.Y.Z\` 整个拷给别人即可，解压就能用；
若装到只读目录（如 Program Files）会自动把配置/日志回退到 `%LOCALAPPDATA%\LegionFanStudio`。

| 想做的事 | 操作 |
|---|---|
| 看当前温度 / 转速 | 托盘 tooltip，或 `fanctl.ps1 status`，或 `exe --status` |
| 换档位（安静/均衡/野兽/满速/自定义） | 托盘菜单，或 `fanctl.ps1 profile quiet` |
| 临时手动转速 | `fanctl.ps1 set 5500 -Seconds 30`（到点自动交还曲线） |
| 满速清灰/压温度 | `fanctl.ps1 boost 20`（20 秒后自动解除） |
| 改 CPU 功耗墙（真正越过电源计划） | `fanctl.ps1 limit 125 145`，或托盘「CPU 功耗墙」 |
| 编辑风扇曲线 | 网页面板，或 `fanctl.ps1 curve set custom cpu "66:3600,...,94:6600"` |
| 开机自动托管 | 双击 **安装开机自启.cmd**（一次性管理员授权），或托盘「开机自启」 |
| 从开始菜单启动 | 安装后搜「Legion Fan Studio」；`-DesktopShortcut` 会额外放一个桌面图标 |
| 一键恢复正常 | **恢复正常.cmd**，或 `fanctl.ps1 reset` |
| 不玩了，交还 BIOS | **卸载.cmd**；或重启电脑（EC 的手动锁存只在重启时清除） |


---

## 为什么这能"绕过电源计划"

Windows 电源计划里的"系统散热方式 / 最大处理器状态"只影响 CPU 升降速策略，**不参与风扇控制** ——
拯救者的风扇由主板上的 EC 按固件里的热策略驱动（Fn+Q 安静/均衡/野兽 就是切 EC 策略）。
本工具直接调用固件自带的 WMI 接口写 EC，所以：

* 转速指令来自 EC 层，电源计划管不到它；
* `limit` 命令改的是 **EC 里的 PL1/PL2 功耗墙**，优先级高于电源计划里的任何设置；
* 唯一在 Windows 侧的依赖是 CPU 占用率采样（用来做"负载预判"，让风扇提前起转）。

## 组件与目录

```
app\LegionFanStudio.cs  原生托盘程序（C# WinForms，仅需系统自带 .NET Framework）
build\build.ps1         编译 exe + 程序化生成 .ico + 组装可移植目录 + 打 zip + SHA256
src\LenovoFan.psm1      核心模块：EC 读写 + 曲线引擎 + 安全护栏 + 日志/锁/可移植数据目录
src\daemon.ps1          守护进程：闭环控速（EC 的唯一写入者）
src\fanctl.ps1          命令行：status/watch/profile/set/boost/limit/curve/daemon/panel/test/diag/version
src\panel.ps1           本地面板服务：TcpListener（HTTP/1.1 keep-alive），无需管理员
src\www\index.html      面板前端：单文件、离线可用、无外部依赖
src\menu.ps1            中文交互菜单（风扇控制.cmd 的实现）
LegionFanStudio.exe     托盘程序（build.ps1 从 dist 镜像过来，已 gitignore）；assets\app.ico 是它的图标
install.ps1 / uninstall.ps1   开机自启计划任务的注册与清理 + 开始菜单/桌面快捷方式的创建与删除
config\config.json      档位曲线 / 安全阈值 / 功耗墙（可手改，守护进程会自动 reload）
docs\实测记录.md        本机 EC 接口的全部实测事实（改代码前必读）
tools\                  单测、端到端验证、安装往返、编码门禁（CI 用的就是这些）
tools\exploration\      逆向 EC 接口时的一次性探针，不进产物，见该目录下的 README
logs\ state\            运行时生成，不入库
```

托盘程序**不重复实现** EC 逻辑：它只读 `state\live.json`、写 `state\cmd.json`，
真正动硬件的仍然只有守护进程。

**为什么守护进程是唯一写入者**：两个进程同时写 EC 会互相打架。面板/托盘要改东西就写
`state\cmd.json`，守护进程下一轮消费；因此它们都不需要管理员权限，也不会出现"谁最后写"的竞态。

## 命令行参数（托盘 exe）

```
LegionFanStudio.exe              启动托盘（单实例，重复启动会提示已在运行）
LegionFanStudio.exe --status     一行输出转速/温度/档位；守护未运行时退出码 2（脚本可判断）
LegionFanStudio.exe --selftest   自检目录/JSON/信报通路，不改动风扇
LegionFanStudio.exe --version    版本号        --help  帮助
```


---

## 安全护栏（都经过实测）

| 风险 | 处理 |
|---|---|
| 命令过低转速导致风扇失速 | 任何写入都被夹到 `rpm_floor`(2400) – `rpm_ceiling`(6600)；**0/极小值/缺参数会被直接拒绝**，而不是回落到下限 |
| 过温 | 近 CPU ≥ 92 °C 或 GPU ≥ 87 °C → 立刻满速，降 8 °C 才自动解除 |
| EC 读不到还瞎写 | 连续 3 次读失败 → 强制满速并告警，不"盲跑" |
| 控制逻辑连续出错 | 连续 3 轮异常 → 写回安全转速（默认满速档），不再盲目控速 |
| 误拖曲线把整条拉平 | `Get-FanCurveIssue` 体检：恒定转速 ≠ 档位上限 → 面板顶部黄字警告 + 守护进程日志告警 |
| 曲线写坏了无法解析 | `Repair-FanConfigCurves` 自愈：临时改用出厂默认该条曲线，日志留痕，控制回路不会中断 |
| 改了配置事后说不清 | `Save-FanConfig` 每次写入都记 **逐项 old → new 差异**（`配置变更[来源]`），旧值另存 `state\config.prev.json` |
| 面板误操作 | 满速/手动保持都有倒计时（`max_hold_s`，默认 900 秒）；到点自动交还曲线；退出写回 `exit_rpm` |
| 两个进程抢 EC | 锁文件 + 命令信箱；`daemon start -Force` 才会顶掉旧实例 |
| 两份安装（仓库版 + dist 版）各起一个守护 | 额外一把**跨目录共享锁** `%LOCALAPPDATA%\LegionFanStudio\daemon.lock`：另一份副本在写 EC 时，本份 `daemon start` 直接拒绝并告诉你对方 pid/数据目录；`fanctl status` 也会显示「另一份安装在托管」 |
| 想反悔 | `reset` 一键恢复；或重启电脑（EC 恢复全自动策略） |

> ⚠️ 三条必须知道的实测事实
> 1. **EC 会一直保持最后一次命令的转速**，重新设置 Fn+Q 档位并不会交还控制权。要彻底还给 BIOS 自动策略，请重启电脑。
> 2. **不要往 `SetFanSpeed` 写 0–255 这类小数字**。该接口的单位是 RPM 本身；本机曾因为按"占空比 0–255"误写 60，导致风扇接近停转、EC 主动把 PL1 从 115 W 砍到 45 W 保护（表现为性能骤降）。工具已用 clamp 挡住这类误操作。
> 3. **每写一次 EC（哪怕写回同一个转速）风扇都会掉回 ~2600 RPM 再重新爬升**，6 秒到中间值、12 秒才稳住。所以守护进程**不做**"每 30 秒重申一次"的心跳写，只在读数确实偏离目标时重申——否则风扇会永无止境地"降下去→轰上来"。

---

## 曲线怎么调

面板里选中档位 → 改 8 个点 → 保存并生效（守护进程立刻按新曲线跑）。

* **CPU 曲线** 的 X 轴不是核心温度，而是 `近 CPU NTC 温度 + 负载预判加成`。
  为什么：本机固件的 `GetCPUTemperature` 读数不随负载正常变化（怠速可到 93 °C），而 `GetNearCPUTemperature`
  是真实 NTC 但热惯性大（温度上来要十几秒）。所以用 CPU 占用率做**预判**（默认每 10% 占用 ≈ +3 °C，上限 +16 °C），
  让风扇在负载刚起来时就开始加速，再由 NTC 做慢反馈。
  想让曲线数字更贴近"核心温度"，把 `温度偏移` 设成 +15 左右即可（整体平移，不影响形状）。
* **GPU 曲线** 的 X 轴是 EC GPU 温度（与 `nvidia-smi` 读数一致，实测 68 °C 对 68 °C）。
* 两个风扇在本机是**同速驱动**的（实测写入不同值后读回一致），所以曲线取两者的较大值作为统一目标。

本机实测参考点（用于判断曲线是否合理）：

| Fn+Q | 怠速自动转速 | 满速 |
|---|---|---|
| 安静 (1) | ≈ 3600 RPM | 6600 |
| 均衡 (2) | ≈ 4000 RPM | 6600 |
| 野兽 (3) | ≈ 4500 RPM | 6600 |

---

## 验证方式

```powershell
# 1) 离线逻辑自检（不需要管理员，不碰硬件）：曲线插值、夹取、格式校验、过温判定
powershell -ExecutionPolicy Bypass -File tools\unit-tests.ps1

# 2) 硬件端到端自检：逐级升速 → 满速 → 自动恢复（只往高提，不会低于安全下限）
powershell -ExecutionPolicy Bypass -File src\fanctl.ps1 test

# 3) 全套（守护进程 + 面板 + 所有 HTTP 接口 + 命令信箱）
powershell -ExecutionPolicy Bypass -File tools\elevrun.ps1 -NoWait -Command '& (Join-Path $root "tools\smoke.ps1")' -Log logs\smoke.log
```

排查问题：`fanctl.ps1 diag`（把输出贴回来即可），日志在 `logs\fan.log`、`logs\panel.log`。

## 常见问题

| 现象 | 原因 / 处理 |
|---|---|
| 面板打开是空白或显示「守护未运行」 | 守护进程没跑。双击 **启动守护进程.cmd**，或 `fanctl.ps1 daemon start`。面板自己不需要管理员 |
| 改了曲线没反应 | 看面板右下「事件日志」有没有 `收到命令 curve`；保存后守护进程下一轮（≤2 s）就会应用 |
| 转速和设定的不一样 | 风扇有 ~12 s 物理升速斜坡，中途读数偏低是正常的；等 12 s 再看 |
| 游戏时性能突然变差 | 大概率是散热被限制、EC 自己砍了 PL1。看 `status` 的 `功耗墙`；把档位切到野兽或调大上限转速 |
| 想把风扇完全还给 BIOS | **重启电脑**（EC 的手动锁存只在重启时清除，这是实测结论） |
| 弹窗要管理员 | 只有写 EC 的操作需要：`daemon start` / `set` / `boost` / `limit` / `profile` / `reset` / `test` |
| 想看是谁在什么时候改了风扇 | `logsan.log`（每次写入都有 ACTION 记录），`logs\history.csv` 是温度转速时间序列 |

## 卸载

双击 **卸载.cmd**：停守护进程、删计划任务、把转速/档位/功耗墙恢复正常值。加 `-Purge` 连日志配置一起删。
