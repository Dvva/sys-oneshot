// ============================================================
// 启动器源码.cs
// BandiView「运行外部编辑器」的启动器（编译成 exe，避免脚本安全警告）
// 作用：隐藏窗口调用同目录下的 主脚本.ps1，并把图片路径传进去
//
// 编译（Windows 自带 .NET Framework，无需装 SDK）：
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe ^
//     /codepage:65001 /target:winexe /out:启动器.exe 启动器源码.cs
// ============================================================
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

static class Program
{
    // 被调用的脚本名（中文文件名，用 \u 转义避免源码编码问题）
    // 主脚本.ps1
    const string SCRIPT_NAME = "\u4E3B\u811A\u672C.ps1";

    [STAThread]
    static void Main(string[] args)
    {
        string logPath = Path.Combine(Path.GetTempPath(), "bv_delete.log");
        try
        {
            if (args.Length < 1) return;

            string image = args[0];
            string dir = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(dir, SCRIPT_NAME);

            if (!File.Exists(script))
            {
                File.AppendAllText(
                    Path.Combine(Path.GetTempPath(), "bv_delete.log"),
                    string.Format("{0:yyyy-MM-dd HH:mm:ss}  错误：找不到脚本 {1}{2}",
                        DateTime.Now, script, Environment.NewLine),
                    Encoding.UTF8);
                return;
            }

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = string.Format(
                    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{0}\" \"{1}\"",
                    script, image),
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            Process.Start(psi);
        }
        catch (Exception ex)
        {
            try
            {
                File.AppendAllText(
                    logPath,
                    string.Format("{0:yyyy-MM-dd HH:mm:ss}  启动器错误：{1}{2}",
                        DateTime.Now, ex.Message, Environment.NewLine),
                    Encoding.UTF8);
            }
            catch { }
        }
    }
}
