# 更新日志

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-09-29

首个版本，面向 Lenovo Legion Y9000P 2022（机型代码 82RF）。

### 新增

- **原生托盘程序** `LegionFanStudio.exe`（C# WinForms，只依赖系统自带的 .NET Framework 4.x，用户端零安装）：
  实时 tooltip 转速/温度、档位与功耗墙菜单、状态窗口、开机自启开关、单实例互斥、`--selftest` 无头自检。
- **可视化调参面板**（`src/panel.ps1` + 单文件 `src/www/index.html`）：实时曲线图、8 点曲线编辑器、
  安全阈值与负载预判设置、事件日志。用 TcpListener 实现 HTTP/1.1 keep-alive + `Expect: 100-continue`，
  普通权限即可运行。
- **命令行** `src/fanctl.ps1`：`status / watch / profile / mode / set / boost / limit / curve /
  daemon / panel / test / reset / diag / config / elevate`。
- **守护进程** `src/daemon.ps1`：曲线闭环控制 —— 滑动平均去抖、升速快降速慢的非对称死区、单次斜率限制、
  最小写入间隔（对齐实测的 12 秒风扇物理斜坡）；过温强制满速并在降温 8 °C 后自动解除；EC 连续读失败
  强制满速；检测到 EC 主动压低 PL1 时自动补转速；退出时写回安全转速。
- **开机自启**：`install.ps1` 注册登录时以最高权限运行的计划任务（无 UAC 弹窗），`uninstall.ps1` 干净移除并恢复正常值。
- **开始菜单 / 桌面入口**：`install.ps1` 会找到托盘 exe（根目录那份，否则最新 `dist\LegionFanStudio-v*\` 那份）
  创建开始菜单快捷方式，`-DesktopShortcut` 再加一个桌面图标；`uninstall.ps1` 只删除确实指向
  `LegionFanStudio.exe` 的那两个 `.lnk`，别的目标一律保留。
- **构建后镜像到根目录**：`build.ps1` 除了 `dist\` 产物，还把 exe + `assets\app.ico` 复制到仓库根目录
  （已 gitignore）。托盘程序按**自己所在目录**决定数据目录，所以根目录那份才和正在运行的守护进程看同一份
  `config/logs/state`；否则它会显示「未托管」。
- **跨副本单写者**：新增共享锁 `%LOCALAPPDATA%\LegionFanStudio\daemon.lock`。以前两份拷贝各自有
  `state\daemon.lock`，可以同时起两个守护进程一起写 EC；现在 `Enter-FanLock` 先看共享锁，
  发现另一份在跑就直接拒绝（`-Force` 才顶掉），`fanctl status` 显示「另一份安装在托管」。
- **构建与发布**：`build/build.ps1` 用系统自带 `csc.exe` 编译、程序化生成 `.ico`、组装可移植目录、打 zip 并输出 SHA256。
- **测试**：离线逻辑单测（52 项）+ 硬件端到端套件（曲线插值/夹取、HTTP 端点、命令信箱、档位落到 Fn+Q、
  手动保持与自动交还、非法曲线与缺失参数被拒绝、怠速空写次数）+ 安装/卸载往返 + 托盘 exe 无头自检（16 项）。
- **文档**：`README.md`（用法、设计、故障排查）与 `docs/实测记录.md`（本机 EC 接口全部实测事实、单位、时序、踩坑）。

### 安全设计

- 转速写入被硬性夹在 2400–6600 RPM；**参数缺失或为 0 时直接拒绝写入**，而不是回落到下限。
- 守护进程是 EC 的唯一写入者，UI/CLI 一律经命令信箱投递，消除多进程竞态。
- 所有 EC 写入都留痕在 `logs/fan.log`，温度转速历史在 `logs/history.csv`。

### 加固与修复（开发期间实测发现）

- **配置写入审计**：`Save-FanConfig` 现在把每次写入展开成逐项 `旧值 -> 新值` 差异并记入日志
  （`配置变更[来源]`，来源如 `panel:curve` / `fanctl:curve-set` / `install`）。起因：面板测试把
  野兽档曲线整条拖平成 5800 RPM，事后无法追查是谁改的。
- **曲线体检**：新增 `Get-FanCurveIssue` —— 转速恒定且不等于档位上限的曲线会被判为疑似误改，
  面板顶部显示警告、守护进程启动/热加载时写 WARN 日志、`fanctl config check` 与 exe 自检都会查。
- **无效曲线自愈**：新增 `Repair-FanConfigCurves`。出厂的「满速」档曲线是 `0:6600` 重复 8 次，
  `Parse-FanCurve` 判定"温度必须递增"而抛错 —— 选中满速档时守护进程每一轮都异常，等于**失去控制**。
  现在改成 `0:6600,20:6600,…,130:6600`，并对用户已有的坏曲线自动临时改用默认值 + 告警（不再中断控速）。
- **取消 30 秒心跳空写**：实测每次写 EC（哪怕写回同一个转速）都会让风扇掉回 ~2600 RPM 再花 6–12 秒爬回来，
  周期性重申 = 风扇永无止境地"降下去→轰上来"。现在只有读数确实偏离目标 >350 RPM 才重申。
- **连续异常兜底**：控制回路连续 3 轮抛异常时写回安全转速（过温状态下写满速），避免 EC 保持一个未知值。
- **`reload` 真正生效**：热加载后刷新缓存的 `rpm_floor/rpm_ceiling/reassert_gap_s` 并立即重算目标，
  此前改了上限要重启守护进程才生效。
- **配置向前兼容**：`Get-FanConfig` 改为递归补齐缺失字段（老 config 文件自动获得 `max_hold_s` 等新键），
  且缺失子树以 PSCustomObject 插入 —— PS 5.1 里 hashtable 的键不通过 `PSObject.Properties` 暴露，
  混用会让所有档位遍历静默漏项。
- **保持转速有上限**：`rpm`/`pause` 命令的保持时间受 `safety.max_hold_s`（默认 900 秒）约束，
  到点自动交还曲线（此前一次测试里的"暂停接管"挂了 2.5 小时没人解除，风扇一直 5800 RPM）。
- **中文启动器 .cmd 全部重写**：仓库根目录那 6 个 `.cmd` 都带 **UTF-8 BOM**，cmd.exe 会把首行
  `@echo off` 当命令报错并把之后每一行都回显出来；而且它们写的是 `>/dev/null`（cmd 里无效）。
  现在统一纯 ASCII 内容 + CRLF + `>nul`，并且**不再** `chcp 65001`（PS 5.1 用 OEM 代码页输出中文，
  切到 65001 反而乱码）。`.gitignore` 也去掉了 BOM（BOM 会让第一条规则失效）。
- **新增 `风扇托盘.cmd`**：双击即启动托盘程序，自己找根目录或最新 `dist\` 里的 exe，找不到就提示先跑 `build\build.ps1`。
- **修掉托盘程序崩溃**：`NotifyIcon.Text` 在 .NET Framework 里上限 63 个字符，而"暂停接管"时的
  提示串（`⏸保持转速中(剩900s) 转速 6600 RPM · 近CPU 62°C · GPU 56°C · 野兽 Performance`，76 字符）
  超限，`set_Text` 抛 `ArgumentOutOfRangeException`；它在计时器回调里没人接，于是**整个托盘进程直接消失**。
  现在：tooltip 由 `Tray.BuildTip()` 统一生成并硬夹到 63 字符以内（紧凑格式 `⏸保持 6600 RPM · CPU 63° GPU 56° · 野兽 剩900s`，
  实测 41 字符），计时器回调包 try/catch 并写 `logs\tray.log`（同一条只记一次），
  `Main` 里加 `Application.ThreadException` / `SetUnhandledExceptionMode(CatchException)`，
  无头自检新增两条断言：常规与保持状态下的 tooltip 都必须 ≤63 字符（有守护进程数据时才跑）。
- **CI 可靠性**（`.github\workflows\test.yml` 重写）：runner 上失败只留一句 `exit code 1`、日志又要权限看，
  所以每一步现在都用 `Stop` + try/catch 并把原因写成 `::error::` / `::notice::` 注解（公开 API 就能读到）；
  正文一律 ASCII（GH 写的临时 .ps1 没有 BOM，PS 5.1 按 GBK 解码中文会吞掉紧随其后的 ASCII 字符）；
  不再用 `Out-String` 捕获 `Write-Host` 的输出做断言（PS 5.1 里 `Write-Host` 走 information stream，`2>&1` 捕不到）；
  每步显式 `exit 0`（GH 的包装会传播 `$LASTEXITCODE`，残留值会把成功的步骤判失败）；
  `upload-artifact` 加 `if-no-files-found: error`；`build.ps1` 的自检失败不再被 try/catch 吞成 warning。

### 已知限制

- 本机 BIOS 不开放 EC 风扇曲线表（`Fan_Get_Table` 返回空、`SetSmartFanMode(4)` 被拒），因此曲线在软件侧计算。
- EC 会**一直保持最后一次命令的转速**，重新设置 Fn+Q 档位不会交还控制权；彻底还给 BIOS 自动策略需重启。
- 实测两个风扇同速驱动，故取 CPU/GPU 双曲线的较大值作为统一目标。
- `Lfc.GetCPUTemperature` 读数不随负载正常变化（怠速即 93–97），控制输入改用 `GetNearCPUTemperature` + CPU 占用预判。
