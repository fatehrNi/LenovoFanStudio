# tools\exploration — 逆向 EC 接口时的一次性探针

这个目录里的东西**不是产品的一部分**，打包时也不会进 `dist\`。它们是我在 2026-09-29 摸清
`ACPI\PNP0C14` 上那几个 Lenovo WMI 类时写的一次性脚本，留在仓库里有两个用处：

1. **可复核**：`docs\实测记录.md` 里的每条结论（单位是 RPM 不是占空比、`SetPowerLimit` 单位是瓦、
   `Fan_Get_Table` 在本机返回空、`GetCPUTemperature` 读数不可信……）都能在这里找到当时跑出它的脚本，
   换一台机器还能再跑一遍验证。
2. **可复现踩坑**：有些脚本会故意写极端值观察 EC 的保护行为。这些脚本**会动风扇**，
   所以它们和 `tools\` 里那套"随时可跑"的测试是分开放置的。

## 怎么跑

绝大多数需要管理员权限（WMI 命名空间 `root\wmi` 的 Lenovo 类返回 0x80041003 就是没提权）：

```powershell
# 用仓库自带的提权助手，输出全部落到日志文件
powershell -NoProfile -ExecutionPolicy Bypass -File ..\elevrun.ps1 `
  -Command "& (Join-Path (Resolve-Path '.') 'tools\exploration\probe8.ps1')" -Log logs\probe8.log
```

## 文件名约定

- `probeN.ps1`：按发现顺序编号的接口探针。`probe1` 只是列出 WMI 类，`probe7/8` 找到风扇与曲线方法，
  `probe12/13` 验证单位，`probe16/17` 记录时序与 EC 保持行为。
- `probe_panel.ps1` / `panel_test.ps1`：面板 HTTP 端点的原始试验。
- `diag2.ps1`、`reload_check.ps1`、`stabilize.ps1`：观察守护进程行为的一次性检查。
- `recover.ps1` / `restore.ps1`：把机器从"EC 保持了错误的转速"里拉回正常值的路径。
  日常请用产品自带的 `src\fanctl.ps1 reset`，这两个只是当时的手工兜底。
- `runas.ps1`：提权启动的早期版本，已被 `tools\elevrun.ps1` 取代。

## 想加新探针

请放**在这个目录**里，不要污染 `tools\` 根目录（那里的每个脚本都会被 CI 或 `final_verify.ps1` 调用，
必须能无人值守地跑完）。新脚本一律 UTF-8 with BOM：改完跑 `..\fix-encoding.ps1`。
