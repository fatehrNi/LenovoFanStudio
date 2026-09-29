# 贡献指南

先读 **[docs/实测记录.md](docs/实测记录.md)**：里面是参考机型（Y9000P 2022 / 82RF）上每个 EC 接口的
**实测**结果 —— 单位、时序、哪台 BIOS 会直接返回空。改 EC 相关代码前必看，很多结论是踩过坑才知道的。

## 环境要求

只要 Windows 10/11 + 系统自带的 Windows PowerShell 5.1（`csc.exe` 也在系统里，用来编译托盘程序）。

**不要引入第三方依赖**（NuGet / pip / npm）。零依赖是这个项目的主要价值之一：任何一台 Windows 机器
解压即用，不需要装运行库、不需要联网。

## 两个必须遵守的工程约定（都有真实事故）

1. **所有 `.ps1` / `.psm1` 必须是 UTF-8 *with BOM***。中文系统上 PowerShell 5.1 会把无 BOM 文件按 GBK
   解码，直接报出莫名其妙的语法错误。提交前跑：
   ```
   powershell -ExecutionPolicy Bypass -File tools\fix-encoding.ps1
   ```
2. **不要用 `Get-Content -Tail` 读活动日志**。在含中文的 UTF-8 日志上它会挂死（与是否有别的进程写入无关，
   已单独复现）。用模块里的 `Get-SharedTailLines` / `Add-SharedText`（`FileStream` + `FileShare.ReadWrite`）。

顺带记几个 PowerShell 语言坑：别名优先级高于函数（所以别用 `R`、`Sv` 这类 1–2 字母函数名）；变量名大小写
不敏感（所以参数不能叫 `$Args`）；函数里赋值脚本级变量必须写 `$script:`；`python3` 在部分 Windows 上是商店
占位程序，要用 `python`。

## 提 PR 前自测

```powershell
# 1) 语法
powershell -ExecutionPolicy Bypass -File tools\syntax.ps1 -Files 'src/LenovoFan.psm1','src/fanctl.ps1','src/daemon.ps1','src/panel.ps1'

# 2) 离线逻辑（不需要管理员，不碰硬件，可在 CI 跑）
powershell -ExecutionPolicy Bypass -File tools\unit-tests.ps1

# 3) 打包 + 产物自检（不改动风扇）
powershell -ExecutionPolicy Bypass -File build\build.ps1
dist\LegionFanStudio-vX.Y.Z\selftest.cmd
```

涉及**真实 EC 写入**的改动，必须在自己的机器上额外跑：

```powershell
powershell -ExecutionPolicy Bypass -File src\fanctl.ps1 test    # 只往高提转速，结束自动恢复
powershell -ExecutionPolicy Bypass -File src\fanctl.ps1 diag    # 把输出贴进 PR
```

## 安全红线（不接受放宽）

- 任何写 EC 的路径都要经过区间夹取；**参数缺失/为 0 必须报错拒绝**，绝不允许静默回落到最低转速。
- 不允许新增"默认降低转速"的行为；降速方向必须比升速更保守（见 `deadband_down` > `deadband_up`）。
- 过温兜底（强制满速）与读失败兜底不能被绕过；`Set-FanFullSpeed -SkipSafety` 只用于收尾路径。
- 守护进程是唯一写入者；新增交互一律走 `state\cmd.json` 信箱，不要另起进程直接写 EC。
- 新机型适配：先只读探测、把实测结论写进 `docs/`，再谈控制能力。

## 目录结构

```
app/                 C# 托盘程序源码（编译成 LegionFanStudio.exe）
build/               图标生成 + 构建打包脚本
src/                 引擎：模块 / 守护进程 / CLI / 面板 / 前端
docs/实测记录.md     本机 EC 接口实测事实（最重要的一份文档）
tools/               单测、端到端验证、安装往返、编码门禁（都会被 CI / final_verify 调用）
tools/exploration/   逆向 EC 接口用的一次性探针，不进构建产物；新写的一次性脚本请放这里
config/ state/ logs/ 运行时生成（不入库）
```
