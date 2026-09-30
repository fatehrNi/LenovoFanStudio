// =============================================================================
//  Legion Fan Studio - 拯救者 Y9000P 2022 风扇管理托盘程序
//
//  本程序只是"外壳"。所有 EC 读写仍由 PowerShell 引擎完成
//  (src\LenovoFan.psm1 + src\daemon.ps1)，托盘通过文件与守护进程通信：
//      读  state\live.json   实时状态
//      写  state\cmd.json    下发命令
//  这样守护进程始终是 EC 的唯一写入者，杜绝两个进程抢写 EC。
//
//  只使用 .NET Framework 4.x 自带能力（WinForms + JavaScriptSerializer），
//  终端用户无需安装任何运行库。语法保持 C# 5 兼容（csc 4.0.30319）。
// =============================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace LegionFanStudio
{
    // ------------------------------------------------------------------ paths
    internal sealed class Paths
    {
        public string Root;         // 含 src\、config\ 的根目录
        public string DataRoot;     // 可写目录（Root 不可写时回退到 %LOCALAPPDATA%）
        public string StateDir;
        public string LogDir;
        public string ConfigDir;
        public string LiveJson;
        public string CmdJson;
        public string FanCtlPs1;
        public string DaemonPs1;
        public string PanelPs1;
        public string ConfigJson;
        public string LockFile;
        public bool Portable;

        private static bool HasEngine(string dir)
        {
            try { return File.Exists(Path.Combine(dir, "src", "LenovoFan.psm1")); }
            catch { return false; }
        }

        private static string FindRoot(string exeDir)
        {
            string[] cand = new string[] {
                exeDir,
                Path.Combine(exeDir, ".."),
                Path.Combine(exeDir, "..", ".."),
                Path.Combine(exeDir, "..", "..", "..")
            };
            for (int i = 0; i < cand.Length; i++)
            {
                try
                {
                    string full = Path.GetFullPath(cand[i]);
                    if (HasEngine(full)) return full;
                }
                catch { }
            }
            return exeDir;
        }

        public static Paths Detect()
        {
            string exeDir = AppDomain.CurrentDomain.BaseDirectory;
            Paths p = new Paths();
            p.Root = FindRoot(exeDir);
            p.FanCtlPs1 = Path.Combine(p.Root, "src", "fanctl.ps1");
            p.DaemonPs1 = Path.Combine(p.Root, "src", "daemon.ps1");
            p.PanelPs1 = Path.Combine(p.Root, "src", "panel.ps1");

            string data = p.Root;
            p.Portable = Writable(data);
            if (!p.Portable)
            {
                data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LegionFanStudio");
                try { Directory.CreateDirectory(data); } catch { }
            }
            p.DataRoot = data;
            p.StateDir = Path.Combine(data, "state");
            p.LogDir = Path.Combine(data, "logs");
            p.ConfigDir = Path.Combine(data, "config");
            TryDir(p.StateDir); TryDir(p.LogDir); TryDir(p.ConfigDir);
            p.LiveJson = Path.Combine(p.StateDir, "live.json");
            p.CmdJson = Path.Combine(p.StateDir, "cmd.json");
            p.LockFile = Path.Combine(p.StateDir, "daemon.lock");
            p.ConfigJson = Path.Combine(p.ConfigDir, "config.json");
            return p;
        }

        private static void TryDir(string d) { try { Directory.CreateDirectory(d); } catch { } }

        private static bool Writable(string dir)
        {
            try
            {
                Directory.CreateDirectory(dir);
                string probe = Path.Combine(dir, ".write-probe");
                File.WriteAllText(probe, "1");
                File.Delete(probe);
                return true;
            }
            catch { return false; }
        }
    }

    // -------------------------------------------------------------- tiny JSON
    internal static class Json
    {
        private static readonly JavaScriptSerializer Ser = NewSer();

        private static JavaScriptSerializer NewSer()
        {
            JavaScriptSerializer s = new JavaScriptSerializer();
            s.MaxJsonLength = 8 * 1024 * 1024;
            s.RecursionLimit = 30;
            return s;
        }

        public static Dictionary<string, object> ReadFile(string path)
        {
            try
            {
                if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
                string text;
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                using (StreamReader sr = new StreamReader(fs, Encoding.UTF8))
                {
                    text = sr.ReadToEnd();
                }
                if (string.IsNullOrEmpty(text)) return null;
                return Ser.DeserializeObject(text) as Dictionary<string, object>;
            }
            catch { return null; }
        }

        public static void WriteFileAtomic(string path, string text)
        {
            string tmp = path + ".tmp";
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            File.Copy(tmp, path, true);
            try { File.Delete(tmp); } catch { }
        }

        public static string Serialize(object o) { return Ser.Serialize(o); }

        public static Dictionary<string, object> Dict(object o) { return o as Dictionary<string, object>; }

        public static object Get(object o, params string[] keys)
        {
            object cur = o;
            for (int i = 0; i < keys.Length; i++)
            {
                Dictionary<string, object> d = cur as Dictionary<string, object>;
                if (d == null || !d.ContainsKey(keys[i])) return null;
                cur = d[keys[i]];
            }
            return cur;
        }

        public static string Str(object o, params string[] keys)
        {
            object v = Get(o, keys);
            return v == null ? "" : Convert.ToString(v, CultureInfo.InvariantCulture);
        }

        public static int Int(object o, int fallback, params string[] keys)
        {
            object v = Get(o, keys);
            if (v == null) return fallback;
            try { return Convert.ToInt32(v, CultureInfo.InvariantCulture); }
            catch { return fallback; }
        }

        public static List<object> Arr(object o, params string[] keys)
        {
            object[] a = Get(o, keys) as object[];
            if (a == null) return new List<object>();
            return new List<object>(a);
        }
    }

    // ------------------------------------------------------------ EC plumbing
    internal sealed class Engine
    {
        private readonly Paths _p;
        private static readonly string Powershell = Path.Combine(
            Environment.GetEnvironmentVariable("WINDIR"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");

        public Engine(Paths p) { _p = p; }

        public bool DaemonRunning
        {
            get
            {
                try
                {
                    Dictionary<string, object> lk = Json.ReadFile(_p.LockFile);
                    if (lk == null) return false;
                    int pid = Json.Int(lk, 0, "pid");
                    if (pid <= 0) return false;
                    try { Process.GetProcessById(pid); return true; }
                    catch { return false; }
                }
                catch { return false; }
            }
        }

        /// 唯一的"写"通道：投给守护进程，由它去动 EC。
        public void Send(string type, Dictionary<string, object> args)
        {
            Dictionary<string, object> msg = new Dictionary<string, object>();
            msg["id"] = unchecked(Environment.TickCount & 0x7FFFFFFF);
            msg["type"] = type;
            msg["args"] = args == null ? new Dictionary<string, object>() : args;
            msg["at"] = DateTime.Now.ToString("o");
            Json.WriteFileAtomic(_p.CmdJson, Json.Serialize(msg));
        }

        public bool PanelAlive(int port)
        {
            try
            {
                using (TcpClient c = new TcpClient())
                {
                    IAsyncResult ar = c.BeginConnect("127.0.0.1", port, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(400, true)) return false;
                    c.EndConnect(ar);
                    return c.Connected;
                }
            }
            catch { return false; }
        }

        public int PanelPort
        {
            get
            {
                int port = Json.Int(Json.ReadFile(_p.ConfigJson), 4765, "panel", "port");
                return port > 0 ? port : 4765;
            }
        }

        public void OpenPanel()
        {
            int port = PanelPort;
            if (!PanelAlive(port))
            {
                try
                {
                    ProcessStartInfo si = new ProcessStartInfo(Powershell);
                    si.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + _p.PanelPs1 + "\" -NoBrowser";
                    si.UseShellExecute = true;
                    si.WindowStyle = ProcessWindowStyle.Hidden;
                    si.WorkingDirectory = _p.Root;
                    Process.Start(si);
                }
                catch { }
                for (int i = 0; i < 25 && !PanelAlive(port); i++) Thread.Sleep(200);
            }
            try
            {
                ProcessStartInfo b = new ProcessStartInfo("http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) + "/");
                b.UseShellExecute = true;
                Process.Start(b);
            }
            catch { }
        }

        public void StartDaemonElevated(string profile)
        {
            ProcessStartInfo si = new ProcessStartInfo(Powershell);
            string arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + _p.DaemonPs1 + "\" -Interval 2";
            if (!string.IsNullOrEmpty(profile)) arg += " -Profile \"" + profile + "\"";
            si.Arguments = arg;
            si.UseShellExecute = true;
            si.Verb = "runas";                       // 只有这一步需要管理员
            si.WindowStyle = ProcessWindowStyle.Hidden;
            try { Process.Start(si); }
            catch (Exception ex)
            {
                MessageBox.Show("启动守护进程失败：\n" + ex.Message + "\n\n（写 EC 需要管理员权限，请在 UAC 里选“是”）",
                    "Legion Fan Studio", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        public void RunScriptElevated(string script, string args)
        {
            if (!File.Exists(script))
            {
                MessageBox.Show("找不到脚本：" + script, "Legion Fan Studio", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            ProcessStartInfo si = new ProcessStartInfo(Powershell);
            si.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" " + args;
            si.UseShellExecute = true;
            si.Verb = "runas";
            si.WorkingDirectory = _p.Root;
            try { Process.Start(si); }
            catch (Exception ex) { MessageBox.Show("执行失败：" + ex.Message, "Legion Fan Studio"); }
        }

        public List<string> TailLog(int count)
        {
            List<string> outp = new List<string>();
            try
            {
                string path = Path.Combine(_p.LogDir, "fan.log");
                if (!File.Exists(path)) return outp;
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                {
                    long len = fs.Length;
                    if (len == 0) return outp;
                    int take = (int)Math.Min(len, 48 * 1024);
                    fs.Seek(-take, SeekOrigin.End);
                    byte[] buf = new byte[take];
                    int read = 0;
                    while (read < take)
                    {
                        int n = fs.Read(buf, read, take - read);
                        if (n <= 0) break;
                        read += n;
                    }
                    string text = Encoding.UTF8.GetString(buf, 0, read);
                    string[] lines = text.Replace("\r\n", "\n").Split('\n');
                    int first = Math.Max(0, lines.Length - count);
                    for (int i = first; i < lines.Length; i++)
                    {
                        if (lines[i].Length > 0) outp.Add(lines[i]);
                    }
                }
            }
            catch { }
            return outp;
        }
    }

    // ------------------------------------------------------------- status UI
    internal class MainForm : Form
    {
        private readonly Paths _p;
        private readonly Engine _e;
        private readonly Label _mode = new Label();
        private readonly Label _rpm = new Label();
        private readonly Label _tgt = new Label();
        private readonly Label _cpu = new Label();
        private readonly Label _gpu = new Label();
        private readonly Label _pl = new Label();
        private readonly Label _daemon = new Label();
        private readonly ProgressBar _bar = new ProgressBar();
        private readonly TextBox _log = new TextBox();
        public Action OnReset;
        public Action OnBoost;

        public MainForm(Paths p, Engine e)
        {
            _p = p; _e = e;
            Text = "Legion Fan Studio · 拯救者 Y9000P 2022";
            StartPosition = FormStartPosition.CenterScreen;
            MinimumSize = new Size(460, 380);
            Size = new Size(520, 460);
            Font = new Font("Microsoft YaHei UI", 9F);
            BackColor = Color.FromArgb(15, 20, 28);
            ForeColor = Color.FromArgb(230, 237, 245);

            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.ColumnCount = 1;
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            _mode.Text = "读取中…";
            _mode.Font = new Font("Microsoft YaHei UI", 14F, FontStyle.Bold);
            _mode.ForeColor = Color.FromArgb(34, 211, 238);
            _mode.AutoSize = true;
            _mode.Padding = new Padding(14, 12, 14, 0);

            _rpm.Text = "— RPM";
            _rpm.Font = new Font("Microsoft YaHei UI", 26F, FontStyle.Bold);
            _rpm.AutoSize = true;
            _rpm.Padding = new Padding(14, 2, 0, 0);
            _tgt.Text = "";
            _tgt.Font = new Font("Microsoft YaHei UI", 10F);
            _tgt.ForeColor = Color.FromArgb(139, 155, 176);
            _tgt.AutoSize = true;
            _tgt.Padding = new Padding(0, 16, 0, 0);

            Panel rpmRow = new Panel();
            rpmRow.AutoSize = true;
            rpmRow.Margin = new Padding(14, 0, 14, 4);
            _rpm.Anchor = AnchorStyles.Left;
            rpmRow.Controls.Add(_rpm);
            rpmRow.Controls.Add(_tgt);

            _bar.Minimum = 0;
            _bar.Maximum = 6600;
            _bar.Height = 12;
            _bar.Margin = new Padding(14, 0, 14, 8);
            _bar.Dock = DockStyle.Fill;

            TableLayoutPanel stats = new TableLayoutPanel();
            stats.ColumnCount = 3;
            stats.RowCount = 2;
            stats.Dock = DockStyle.Fill;
            stats.Margin = new Padding(10, 0, 10, 8);
            for (int i = 0; i < 3; i++) stats.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 33));
            _cpu.Text = "近 CPU  —";
            _gpu.Text = "GPU  —";
            _pl.Text = "PL1/PL2  —";
            _daemon.Text = "守护进程：—";
            Label envL = new Label();
            envL.Text = "内存/环境  —";
            envL.AutoSize = true;
            Label modeL = new Label();
            modeL.Text = "模式  —";
            modeL.AutoSize = true;
            Label[] cells = new Label[] { _cpu, _gpu, _pl, _daemon, envL, modeL };
            for (int i = 0; i < cells.Length; i++)
            {
                cells[i].Font = new Font("Microsoft YaHei UI", 9.5F);
                cells[i].AutoSize = true;
                cells[i].Margin = new Padding(4, 2, 4, 2);
                stats.Controls.Add(cells[i], i % 3, i / 3);
            }
            _cpu.ForeColor = _gpu.ForeColor = Color.FromArgb(245, 158, 11);

            _log.Multiline = true;
            _log.ReadOnly = true;
            _log.ScrollBars = ScrollBars.Vertical;
            _log.Font = new Font("Consolas", 8.5F);
            _log.BackColor = Color.FromArgb(13, 19, 27);
            _log.ForeColor = Color.FromArgb(169, 188, 212);
            _log.BorderStyle = BorderStyle.None;
            _log.Dock = DockStyle.Fill;
            _log.WordWrap = false;
            Panel logWrap = new Panel();
            logWrap.Dock = DockStyle.Fill;
            logWrap.Padding = new Padding(14, 4, 14, 6);
            logWrap.Controls.Add(_log);

            FlowLayoutPanel btns = new FlowLayoutPanel();
            btns.Dock = DockStyle.Fill;
            btns.AutoSize = true;
            btns.Padding = new Padding(10, 6, 10, 10);
            btns.Controls.Add(MakeButton("🌐 网页调参面板", delegate { _e.OpenPanel(); }));
            btns.Controls.Add(MakeButton("↺ 恢复正常", delegate { if (OnReset != null) OnReset(); }));
            btns.Controls.Add(MakeButton("⚡ 满速 20 秒", delegate { if (OnBoost != null) OnBoost(); }));
            btns.Controls.Add(MakeButton("刷新", delegate { RefreshData(); }));

            root.Controls.Add(_mode, 0, 0);
            root.Controls.Add(rpmRow, 0, 1);
            root.Controls.Add(_bar, 0, 2);
            root.Controls.Add(logWrap, 0, 3);
            root.Controls.Add(btns, 0, 4);
            // stats 放在 bar 与 log 之间：再插一行
            root.RowStyles.Insert(3, new RowStyle(SizeType.AutoSize));
            root.SetCellPosition(stats, new TableLayoutPanelCellPosition(0, 3));
            root.Controls.Add(stats);
            root.SetCellPosition(logWrap, new TableLayoutPanelCellPosition(0, 4));
            root.SetCellPosition(btns, new TableLayoutPanelCellPosition(0, 5));
            Controls.Add(root);

            RefreshData();
        }

        private static Button MakeButton(string text, EventHandler onClick)
        {
            Button b = new Button();
            b.Text = text;
            b.AutoSize = true;
            b.FlatStyle = FlatStyle.Flat;
            b.FlatAppearance.BorderColor = Color.FromArgb(37, 48, 63);
            b.BackColor = Color.FromArgb(27, 35, 47);
            b.ForeColor = Color.FromArgb(230, 237, 245);
            b.Margin = new Padding(0, 0, 8, 0);
            b.Cursor = Cursors.Hand;
            b.Click += onClick;
            return b;
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing)
            {
                e.Cancel = true;
                Hide();          // 关窗口 = 回托盘，不退出
            }
            base.OnFormClosing(e);
        }

        public void RefreshData()
        {
            Dictionary<string, object> live = Json.ReadFile(_p.LiveJson);
            if (live == null)
            {
                _mode.Text = "守护进程未运行";
                _rpm.Text = "— RPM";
                _tgt.Text = "  菜单里「启动守护进程」后这里有数据";
                _bar.Value = 0;
                _daemon.Text = "守护进程：未运行";
                return;
            }
            Dictionary<string, object> snap = Json.Dict(live["snap"]);
            int rpm = Json.Int(snap, 0, "rpm");
            int ceiling = Json.Int(live, 6600, "safety", "rpm_ceiling");
            _mode.Text = Json.Str(live, "label") + " 档  ·  " + Json.Str(snap, "mode_name");
            _rpm.Text = rpm.ToString(CultureInfo.InvariantCulture) + " RPM";
            _bar.Maximum = ceiling > 0 ? ceiling : 6600;
            _bar.Value = Math.Max(_bar.Minimum, Math.Min(_bar.Maximum, rpm));
            int tgt = Json.Int(live, 0, "last_target");
            int boostLeft = Json.Int(live, 0, "boost_remaining");
            _tgt.Text = "  目标 " + (tgt > 0 ? tgt.ToString(CultureInfo.InvariantCulture) : "—")
                + " RPM · 引擎 " + Json.Str(live, "mode")
                + (boostLeft > 0 ? " · 倒计时 " + boostLeft.ToString(CultureInfo.InvariantCulture) + "s" : "");
            _cpu.Text = "近 CPU " + Json.Int(snap, 0, "near_cpu") + " °C";
            _gpu.Text = "GPU " + Json.Int(snap, 0, "gpu_c") + " °C";
            _pl.Text = "PL1 " + Json.Int(snap, 0, "pl1") + "W · PL2 " + Json.Int(snap, 0, "pl2") + "W";
            _daemon.Text = "守护进程：" + (_e.DaemonRunning ? "运行中 pid " + Json.Int(live, 0, "pid") : "未运行");
            Label[] find = new Label[] { };
            _rpm.ForeColor = rpm >= (_bar.Maximum - 300) ? Color.FromArgb(239, 68, 68) : Color.FromArgb(103, 232, 249);
            _cpu.ForeColor = Json.Int(snap, 0, "near_cpu") >= 90 ? Color.FromArgb(239, 68, 68) : Color.FromArgb(245, 158, 11);
            _gpu.ForeColor = Json.Int(snap, 0, "gpu_c") >= 85 ? Color.FromArgb(239, 68, 68) : Color.FromArgb(245, 158, 11);
            List<string> lines = _e.TailLog(16);
            _log.Text = string.Join(Environment.NewLine, lines.ToArray());
        }
    }

    // ------------------------------------------------------------- tray app
    // NotifyIcon.Text is limited to 63 characters in .NET Framework. A longer string throws
    // ArgumentOutOfRangeException ("文本长度必须少于 64 个字符") on the timer thread; unhandled,
    // it killed the whole tray app the moment a hold started.
    internal static class Tray
    {
        public const int MaxTipChars = 63;

        public static string Clamp(string s, int max)
        {
            if (string.IsNullOrEmpty(s)) return string.Empty;
            if (s.Length <= max) return s;
            if (max <= 1) return s.Substring(0, max);
            return s.Substring(0, max - 1) + "…";
        }

        public static string BuildTip(Dictionary<string, object> live, bool daemonRunning)
        {
            if (live == null)
            {
                string idle = daemonRunning ? "Legion Fan Studio · 守护进程启动中…" : "Legion Fan Studio · 未接管风扇";
                return Clamp(idle, MaxTipChars);
            }
            Dictionary<string, object> snap = Json.Dict(live["snap"]);
            string body = Json.Int(snap, 0, "rpm") + " RPM · CPU " + Json.Int(snap, 0, "near_cpu")
                        + "° GPU " + Json.Int(snap, 0, "gpu_c") + "° · " + Json.Str(live, "label");
            string engine = Json.Str(live, "mode");
            if (engine == "crit") return Clamp("🔥过温满速 " + body, MaxTipChars);
            int holdLeft = Json.Int(live, 0, "hold_remaining");
            if (engine == "hold" || Json.Int(live, 0, "paused") == 1 || holdLeft > 0)
            {
                string left = holdLeft > 0 ? " 剩" + holdLeft.ToString(CultureInfo.InvariantCulture) + "s" : "";
                return Clamp("⏸保持 " + body + left, MaxTipChars);
            }
            return Clamp(body, MaxTipChars);
        }
    }

    internal class App : ApplicationContext
    {
        private readonly Paths _p;
        private readonly Engine _e;
        private NotifyIcon _tray;
        private readonly ContextMenuStrip _menu = new ContextMenuStrip();
        private readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer();
        private readonly Dictionary<string, ToolStripMenuItem> _profileItems = new Dictionary<string, ToolStripMenuItem>();
        private MainForm _form;
        private Dictionary<string, object> _live;
        private static readonly string[] ProfileKeys = new string[] { "quiet", "balanced", "performance", "max", "custom" };
        private static readonly string[] ProfileLabels = new string[] { "🔇 安静", "⚖️ 均衡", "🚀 野兽", "🌪 满速", "🎛 自定义" };

        public App()
        {
            _p = Paths.Detect();
            _e = new Engine(_p);
            _tray = new NotifyIcon();
            _tray.Icon = LoadIcon(_p);
            _tray.Text = "Legion Fan Studio";
            _tray.Visible = true;
            _tray.DoubleClick += delegate { ShowForm(); };
            BuildMenu();
            _tray.ContextMenuStrip = _menu;
            _timer.Interval = 1200;
            // Anything thrown here is an unhandled exception on the UI thread and takes the tray
            // down with it. Refresh must never be fatal: log once and keep ticking.
            _timer.Tick += delegate
            {
                try { Refresh(); } catch (Exception ex) { LogOnce("refresh 失败: " + ex.Message); }
            };
            _timer.Start();
            try { Refresh(); } catch (Exception ex) { LogOnce("首次刷新失败: " + ex.Message); }
            Balloon();
        }

        private string _lastLogged = "";

        private void LogOnce(string msg)
        {
            if (msg == _lastLogged) return;          // do not repeat the same failure every tick
            _lastLogged = msg;
            try
            {
                if (!Directory.Exists(_p.LogDir)) Directory.CreateDirectory(_p.LogDir);
                File.AppendAllText(Path.Combine(_p.LogDir, "tray.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [WARN ] " + msg + Environment.NewLine,
                    new UTF8Encoding(false));
            }
            catch { }
        }

        private static Icon LoadIcon(Paths p)
        {
            string[] cand = new string[] {
                Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "assets", "app.ico"),
                Path.Combine(p.Root, "assets", "app.ico")
            };
            for (int i = 0; i < cand.Length; i++)
            {
                try { if (File.Exists(cand[i])) return new Icon(cand[i]); } catch { }
            }
            try { return Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            return SystemIcons.Application;
        }

        private void Balloon()
        {
            try
            {
                _tray.BalloonTipTitle = "Legion Fan Studio 已在托盘运行";
                _tray.BalloonTipText = _e.DaemonRunning
                    ? "正在托管风扇。双击托盘图标看状态，右键换档位。"
                    : "右键托盘图标 →「启动守护进程」（需要管理员授权）才会接管风扇。";
                _tray.ShowBalloonTip(5000);
            }
            catch { }
        }

        private void BuildMenu()
        {
            AddItem("读取中…", null, false, "header");
            Sep();
            ToolStripMenuItem profiles = new ToolStripMenuItem("档位");
            for (int i = 0; i < ProfileKeys.Length; i++)
            {
                string key = ProfileKeys[i];
                ToolStripMenuItem it = new ToolStripMenuItem(ProfileLabels[i]);
                it.Tag = key;
                it.Click += delegate(object s, EventArgs ev) { SendProfile((string)((ToolStripMenuItem)s).Tag); };
                _profileItems[key] = it;
                profiles.DropDownItems.Add(it);
            }
            _menu.Items.Add(profiles);

            AddItem("⚡ 满速 20 秒（自动解除）", delegate { Send("boost", Num("sec", 20)); });
            AddItem("⏸ 暂停接管（保持当前转速）", delegate { Send("pause", null); });
            AddItem("▶ 恢复曲线控制", delegate { Send("resume", null); });
            AddItem("↺ 恢复正常值", delegate { Send("reset", null); });

            ToolStripMenuItem limits = new ToolStripMenuItem("🔋 CPU 功耗墙（EC 层，覆盖电源计划）");
            AddLimit(limits, "默认 115 / 135 W", 115, 135);
            AddLimit(limits, "高性能 125 / 145 W", 125, 145);
            AddLimit(limits, "凉爽 95 / 120 W", 95, 120);
            AddLimit(limits, "安静 65 / 90 W", 65, 90);
            limits.DropDownItems.Add(new ToolStripSeparator());
            ToolStripMenuItem keep = new ToolStripMenuItem("让守护进程持续钉住上面的功耗墙（开/关切换）");
            keep.Click += delegate { ToggleKeepPl(); };
            limits.DropDownItems.Add(keep);
            _menu.Items.Add(limits);
            Sep();
            AddItem("▶ 启动守护进程（需管理员）", delegate { StartDaemon(); }, true, "start");
            AddItem("■ 停止守护进程", delegate { Send("stop", null); }, true, "stop");
            Sep();
            AddItem("📊 状态窗口", delegate { ShowForm(); });
            AddItem("🌐 网页调参面板", delegate { _e.OpenPanel(); });
            ToolStripMenuItem auto = new ToolStripMenuItem("🔗 开机自启（登录时托管）…");
            auto.Click += delegate { AutostartPrompt(); };
            _menu.Items.Add(auto);
            AddItem("ℹ 关于 / 帮助", delegate { About(); });
            Sep();
            AddItem("退出", delegate { Quit(); });
        }

        private void AddItem(string text, EventHandler handler, bool keepEnabled, string name)
        {
            ToolStripMenuItem it = new ToolStripMenuItem(text);
            it.Name = name ?? text;
            if (handler != null) it.Click += handler;
            if (handler == null) it.Enabled = false;
            _menu.Items.Add(it);
        }
        private void AddItem(string text, EventHandler handler) { AddItem(text, handler, true, null); }
        private void Sep() { _menu.Items.Add(new ToolStripSeparator()); }

        private void AddLimit(ToolStripMenuItem parent, string text, int pl1, int pl2)
        {
            ToolStripMenuItem it = new ToolStripMenuItem(text);
            it.Tag = new int[] { pl1, pl2 };
            it.Click += delegate(object s, EventArgs ev)
            {
                int[] v = (int[])((ToolStripMenuItem)s).Tag;
                Dictionary<string, object> a = new Dictionary<string, object>();
                a["pl1"] = v[0];
                a["pl2"] = v[1];
                Send("limit", a);
            };
            parent.DropDownItems.Add(it);
        }

        private static Dictionary<string, object> Num(string k, int v)
        {
            Dictionary<string, object> a = new Dictionary<string, object>();
            a[k] = v;
            return a;
        }

        private void Send(string type, Dictionary<string, object> args)
        {
            try { _e.Send(type, args); }
            catch (Exception ex) { MessageBox.Show("命令发送失败：" + ex.Message, "Legion Fan Studio"); }
        }

        private void SendProfile(string name)
        {
            Dictionary<string, object> a = new Dictionary<string, object>();
            a["profile"] = name;
            Send("profile", a);
        }

        private void ToggleKeepPl()
        {
            try
            {
                Dictionary<string, object> cfg = Json.ReadFile(_p.ConfigJson);
                Dictionary<string, object> power = Json.Dict(cfg == null ? null : cfg["power"]);
                if (power == null) { MessageBox.Show("还没生成 config.json，先启动一次守护进程。", "Legion Fan Studio"); return; }
                bool cur = false;
                object v;
                if (power.TryGetValue("keep_pl", out v) && v != null) cur = Convert.ToBoolean(v);
                power["keep_pl"] = !cur;
                Json.WriteFileAtomic(_p.ConfigJson, Json.Serialize(cfg));
                Send("reload", null);
                MessageBox.Show("功耗墙钉住：" + (!cur ? "开（守护进程会把 PL1/PL2 拉回 config 里的值）" : "关（交回 EC 自适应）"),
                    "Legion Fan Studio");
            }
            catch (Exception ex) { MessageBox.Show("切换失败：" + ex.Message, "Legion Fan Studio"); }
        }

        private void StartDaemon()
        {
            _e.StartDaemonElevated(_live == null ? "" : Json.Str(_live, "profile"));
        }

        private void ShowForm()
        {
            if (_form == null || _form.IsDisposed)
            {
                _form = new MainForm(_p, _e);
                _form.Icon = _tray.Icon;
                _form.OnReset = delegate { Send("reset", null); };
                _form.OnBoost = delegate { Send("boost", Num("sec", 20)); };
            }
            _form.Show();
            _form.BringToFront();
            _form.RefreshData();
        }

        private void Refresh()
        {
            _live = Json.ReadFile(_p.LiveJson);
            string tip = Tray.BuildTip(_live, _e.DaemonRunning);
            if (_tray.Text != tip) _tray.Text = tip;

            ToolStripItem header = _menu.Items["header"];
            if (header != null)
            {
                if (_live == null) header.Text = _e.DaemonRunning ? "守护进程启动中…" : "未接管：右键「启动守护进程」";
                else header.Text = "当前 " + Json.Str(_live, "label") + "  ·  目标 "
                    + Json.Int(_live, 0, "last_target") + " RPM（" + Json.Str(_live, "mode") + "）";
            }
            string active = _live == null ? "" : Json.Str(_live, "profile");
            foreach (KeyValuePair<string, ToolStripMenuItem> kv in _profileItems)
            {
                kv.Value.Checked = string.Equals(kv.Key, active, StringComparison.OrdinalIgnoreCase);
                kv.Value.Enabled = _live != null;
            }
            ToolStripItem start = _menu.Items["start"];
            ToolStripItem stop = _menu.Items["stop"];
            if (start != null) start.Visible = !_e.DaemonRunning;
            if (stop != null) stop.Visible = _e.DaemonRunning;
            if (_form != null && _form.Visible) _form.RefreshData();
        }

        private void AutostartPrompt()
        {
            string msg = "「是」开启：登录时以最高权限自动启动守护进程（无 UAC 弹窗）\n"
                       + "「否」关闭：删除计划任务并停止守护进程\n"
                       + "「取消」不做改动\n\n计划任务名：" + Program.TaskName;
            DialogResult r = MessageBox.Show(msg, "开机自启", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);
            if (r == DialogResult.Yes) _e.RunScriptElevated(Path.Combine(_p.Root, "install.ps1"), "-TaskName " + Program.TaskName);
            else if (r == DialogResult.No) _e.RunScriptElevated(Path.Combine(_p.Root, "uninstall.ps1"), "-TaskName " + Program.TaskName);
        }

        private void About()
        {
            Dictionary<string, object> cfg = Json.ReadFile(_p.ConfigJson);
            string info = "Legion Fan Studio " + Program.Version() + "\n\n"
                + "机型：Lenovo Legion Y9000P 2022 (82RF) 等带 GameZone/Lfc 固件 WMI 接口的拯救者\n"
                + "原理：直接读写 EC（root\\wmi\\LENOVO_FAN_METHOD + Lfc_thermal_interface），与 Windows 电源计划无关\n\n"
                + "转速区间：" + Json.Int(cfg, 2400, "safety", "rpm_floor") + " – " + Json.Int(cfg, 6600, "safety", "rpm_ceiling") + " RPM\n"
                + "数据目录：" + _p.DataRoot + (_p.Portable ? "（便携）" : "（用户目录）") + "\n"
                + "命令行：  " + _p.FanCtlPs1 + "\n\n"
                + "注意：EC 会保持最后一次命令的转速；完全交还 BIOS 自动策略请重启电脑。\n"
                + "本项目与联想无关，操作 EC 有风险，请先读 docs\\实测记录.md。";
            MessageBox.Show(info, "关于", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private void Quit()
        {
            _timer.Stop();
            _tray.Visible = false;
            _tray.Dispose();
            ExitThread();
        }
    }

    // --------------------------------------------------------------- entry
    internal static class Program
    {
        public const string TaskName = "LegionFanStudio-FanDaemon";

        [STAThread]
        public static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            // A winexe has no console of its own; when its stdout is redirected (CI,
            // pipes, `> file`) .NET still encodes with the OEM codepage, which mangles
            // Chinese. Fix it up for the text modes only.
            try { if (Console.IsOutputRedirected) Console.OutputEncoding = Encoding.UTF8; } catch { }

            if (args.Length > 0 && (args[0] == "--selftest" || args[0] == "-t"))
            {
                Environment.Exit(SelfTest.Run());
                return;
            }
            if (args.Length > 0 && (args[0] == "--status" || args[0] == "-s"))
            {
                Environment.Exit(StatusLine());
                return;
            }
            if (args.Length > 0 && (args[0] == "--version" || args[0] == "-v"))
            {
                Console.WriteLine("Legion Fan Studio " + Version());
                return;
            }
            if (args.Length > 0 && (args[0] == "--help" || args[0] == "-h"))
            {
                Console.WriteLine("Legion Fan Studio " + Version() + " —— 拯救者 Y9000P 2022 风扇管理\n\n"
                    + "  （无参数）      启动托盘程序\n"
                    + "  --status       一行输出当前转速/温度/档位（脚本可用）\n"
                    + "  --selftest     自检环境与文件链路（不会改动风扇）\n"
                    + "  --version      显示版本\n"
                    + "  --help         本帮助\n\n"
                    + "命令行工具：  src\\fanctl.ps1 status|profile|set|boost|limit|curve|daemon|panel|test|diag|version\n"
                    + "网页面板：    src\\panel.ps1   →  http://127.0.0.1:4765/");
                return;
            }

            bool created;
            Mutex single = new Mutex(true, "Local\\LegionFanStudio.SingleInstance", out created);
            if (!created)
            {
                MessageBox.Show("Legion Fan Studio 已经在运行（看任务栏右侧托盘）。", "Legion Fan Studio",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }
            try
            {
                // A tray app has no window to close; an unhandled UI exception would silently
                // remove the icon and leave the user thinking the app vanished. Catch, report
                // once, keep running.
                Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
                Application.ThreadException += delegate(object sender, System.Threading.ThreadExceptionEventArgs te)
                {
                    try
                    {
                        MessageBox.Show("界面线程出现异常（已忽略，程序继续运行）：\n" + te.Exception.Message,
                            "Legion Fan Studio", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    }
                    catch { }
                };
                Application.Run(new App());
            }
            finally
            {
                try { single.ReleaseMutex(); single.Dispose(); } catch { }
            }
        }

        /// <summary>Machine-friendly one-line status; exit 0 = daemon托管中, 2 = 未托管.</summary>
        private static int StatusLine()
        {
            Paths p = Paths.Detect();
            Dictionary<string, object> live = Json.ReadFile(p.LiveJson);
            Engine e = new Engine(p);
            if (live == null)
            {
                Console.WriteLine("未托管：守护进程没有运行（数据目录 " + p.DataRoot + "）");
                return 2;
            }
            Dictionary<string, object> snap = Json.Dict(live["snap"]);
            Console.WriteLine(string.Format(CultureInfo.InvariantCulture,
                "档位={0} 转速={1}RPM 目标={2} 近CPU={3}°C GPU={4}°C PL1={5}W PL2={6}W 引擎={7} 守护={8}",
                Json.Str(live, "label"), Json.Int(snap, 0, "rpm"), Json.Int(live, 0, "last_target"),
                Json.Int(snap, 0, "near_cpu"), Json.Int(snap, 0, "gpu_c"), Json.Int(snap, 0, "pl1"),
                Json.Int(snap, 0, "pl2"), Json.Str(live, "mode"), e.DaemonRunning ? "运行中" : "未运行"));
            return e.DaemonRunning ? 0 : 2;
        }

        public static string Version()
        {
            try
            {
                System.Reflection.AssemblyFileVersionAttribute av =
                    Attribute.GetCustomAttribute(typeof(Program).Assembly, typeof(System.Reflection.AssemblyFileVersionAttribute))
                    as System.Reflection.AssemblyFileVersionAttribute;
                if (av != null) return av.Version;
            }
            catch { }
            return typeof(Program).Assembly.GetName().Version.ToString(3);
        }
    }

    // ------------------------------------------------------------- selftest
    // 无头自检：验证目录解析、JSON 读取、与守护进程的信箱通路。
    // 只发 reload（对硬件是空操作），绝不改动转速。
    internal static class SelfTest
    {
        private static int _fail;

        private static void Chk(string name, bool ok, string detail)
        {
            Console.WriteLine((ok ? "  PASS  " : "  FAIL  ") + name + (string.IsNullOrEmpty(detail) ? "" : "   " + detail));
            if (!ok) _fail++;
        }
        private static void Chk(string name, bool ok) { Chk(name, ok, ""); }

        // Mirrors Parse-FanCurve / Get-FanCurveIssue in LenovoFan.psm1. The shipped v1
        // "满速" profile used 0:6600 eight times, which Parse-FanCurve rejects, so the
        // daemon threw on every control pass and silently stopped controlling the fan.
        internal static string CurveProblem(string spec, int ceilingRpm)
        {
            if (string.IsNullOrEmpty(spec) || spec.Trim().Length == 0) return "empty";
            string[] parts = spec.Split(new char[] { ',', ';', '，', '；' });
            double prev = -100000.0;
            int rpm0 = -1;
            bool flat = true;
            int n = 0;
            foreach (string raw in parts)
            {
                string t = raw.Trim();
                if (t.Length == 0) continue;
                string[] kv = t.Split(new char[] { ':', '：' });
                if (kv.Length != 2) return "bad token '" + t + "'";
                double tt; int rr;
                if (!double.TryParse(kv[0].Trim(), out tt) || !int.TryParse(kv[1].Trim(), out rr)) return "bad number '" + t + "'";
                if (tt <= prev) return "temp " + tt + " not increasing";
                if (tt < -20 || tt > 130) return "temp " + tt + " out of range";
                if (rr < 0 || rr > 9999) return "rpm " + rr + " out of range";
                if (rpm0 < 0) rpm0 = rr; else if (rr != rpm0) flat = false;
                prev = tt; n++;
            }
            if (n < 2) return "fewer than 2 points";
            if (flat && rpm0 != ceilingRpm) return "flat at " + rpm0 + " RPM while the ceiling is " + ceilingRpm + " (looks like a dragged slider)";
            return null;
        }

        public static int Run()
        {
            Console.WriteLine("Legion Fan Studio " + Program.Version() + " selftest");
            Paths p = Paths.Detect();
            Chk("root resolved", File.Exists(p.FanCtlPs1), p.Root);
            Chk("data dir location", true, p.Portable ? "portable: " + p.DataRoot : "user: " + p.DataRoot);
            Chk("daemon script present", File.Exists(p.DaemonPs1));
            Chk("panel script present", File.Exists(p.PanelPs1));
            Chk("state dir writable", TryWrite(p.StateDir));
            Chk("log dir writable", TryWrite(p.LogDir));

            Dictionary<string, object> cfg = Json.ReadFile(p.ConfigJson);
            Chk("config.json readable", cfg != null, p.ConfigJson);
            if (cfg != null)
            {
                Chk("profiles section", Json.Dict(cfg["profiles"]) != null);
                int ceil = Json.Int(cfg, 0, "safety", "rpm_ceiling");
                int floor = Json.Int(cfg, 0, "safety", "rpm_floor");
                Chk("safety numbers sane", ceil > floor && ceil <= 6600 && floor >= 1500, "floor=" + floor + " ceiling=" + ceil);
                Chk("curve spec parses", Json.Get(cfg, "profiles", "performance", "cpu") != null);
                int badCurves = 0;
                string badDetail = "";
                Dictionary<string, object> profs = Json.Dict(cfg["profiles"]);
                if (profs != null)
                {
                    foreach (KeyValuePair<string, object> pr in profs)
                    {
                        Dictionary<string, object> pv = Json.Dict(pr.Value);
                        if (pv == null) continue;
                        int cap = Json.Int(pv, ceil, "ceiling");
                        string[] sides = new string[] { "cpu", "gpu" };
                        foreach (string side in sides)
                        {
                            string why = CurveProblem(Json.Str(pv, side), cap);
                            if (why != null)
                            {
                                badCurves++;
                                if (badDetail.Length < 160) badDetail += pr.Key + "." + side + ": " + why + "; ";
                            }
                        }
                    }
                }
                Chk("all profile curves are usable", badCurves == 0, badDetail);
            }

            Dictionary<string, object> live = Json.ReadFile(p.LiveJson);
            if (live == null)
            {
                Console.WriteLine("  SKIP  live.json (daemon not running)");
            }
            else
            {
                Dictionary<string, object> snap = Json.Dict(live["snap"]);
                int rpm = Json.Int(snap, -1, "rpm");
                Chk("snap rpm sane", rpm > 500, "rpm=" + rpm);
                Chk("profile name", Json.Str(live, "profile").Length > 0, Json.Str(live, "profile"));
                Chk("series array", Json.Arr(live, "series") != null, "n=" + Json.Arr(live, "series").Count);
                Chk("nested desired read", Json.Get(live, "desired", "rpm") != null, "desired=" + Json.Int(live, -1, "desired", "rpm"));
                // the tray tooltip must survive NotifyIcon's 63-char limit in every engine state
                string tip = Tray.BuildTip(live, true);
                Chk("tooltip fits NotifyIcon (<= 63)", tip.Length <= Tray.MaxTipChars, "len=" + tip.Length + " :: " + tip);
                Dictionary<string, object> holdState = new Dictionary<string, object>(live);
                holdState["mode"] = "hold";
                holdState["hold_remaining"] = 900;
                holdState["paused"] = 1;
                string tipHold = Tray.BuildTip(holdState, true);
                Chk("tooltip fits while holding", tipHold.Length <= Tray.MaxTipChars, "len=" + tipHold.Length + " :: " + tipHold);
            }

            Engine e = new Engine(p);
            Chk("daemon state readable", true, e.DaemonRunning ? "running" : "not running");
            try
            {
                if (File.Exists(p.CmdJson)) File.Delete(p.CmdJson);
                e.Send("reload", new Dictionary<string, object>());
                Dictionary<string, object> back = Json.ReadFile(p.CmdJson);
                Chk("mailbox round-trip", back != null && Json.Str(back, "type") == "reload");
                bool consumed = true;
                if (e.DaemonRunning)
                {
                    DateTime until = DateTime.Now.AddSeconds(12);
                    consumed = false;
                    while (DateTime.Now < until)
                    {
                        if (!File.Exists(p.CmdJson)) { consumed = true; break; }
                        Thread.Sleep(400);
                    }
                }
                Chk("mailbox consumed", consumed, e.DaemonRunning ? "daemon picked it up" : "skipped (no daemon)");
                if (File.Exists(p.CmdJson)) File.Delete(p.CmdJson);
            }
            catch (Exception ex) { Chk("mailbox", false, ex.Message); }

            Chk("log tail non-blocking", true, "lines=" + e.TailLog(5).Count);
            Console.WriteLine(_fail == 0 ? "SELFTEST ALL PASS" : ("SELFTEST " + _fail + " FAILURES"));
            return _fail == 0 ? 0 : 1;
        }

        private static bool TryWrite(string dir)
        {
            try
            {
                string f = Path.Combine(dir, ".probe-" + Guid.NewGuid().ToString("N"));
                File.WriteAllText(f, "x");
                File.Delete(f);
                return true;
            }
            catch { return false; }
        }
    }
}
