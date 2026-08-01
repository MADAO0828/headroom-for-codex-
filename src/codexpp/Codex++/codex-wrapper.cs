using System;
using System.Diagnostics;
using System.IO;
using Microsoft.Win32;
using System.Text;

class CodexWrapper
{
    const string CodexPackagePrefix = "OpenAI.Codex_";
    const string CodexExecutableRelativePath = @"app\resources\codex.exe";
    const string PackageRegistryPath = @"Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages";

    static int Main(string[] args)
    {
        string codexHome = @"C:\Users\ma dao\.codex-plus-plus-cli";
        string apiKeyEnv = @"CUSTOM_OPENAI_API_KEY";
        Directory.CreateDirectory(codexHome);
        string logPath = Path.Combine(codexHome, "codex-wrapper.log");
        AppendLog(logPath, "codex-wrapper start argc=" + args.Length + " args=" + RedactArguments(args));
        AppendLog(logPath, "CODEX_HOME=" + codexHome);
        AppendLog(logPath, "api_key_env=" + apiKeyEnv + " api_key_present=false");

        try
        {
            string realCodex = FindRealCodex();
            AppendLog(logPath, "real_codex=" + realCodex);

            var startInfo = new ProcessStartInfo(realCodex);
            startInfo.UseShellExecute = false;
            startInfo.RedirectStandardInput = false;
            startInfo.RedirectStandardOutput = false;
            startInfo.RedirectStandardError = false;
            startInfo.EnvironmentVariables["CODEX_HOME"] = codexHome;
            startInfo.Arguments = BuildArguments(args);

            using (var process = Process.Start(startInfo))
            {
                if (process == null) throw new InvalidOperationException("Process.Start returned no process.");
                process.WaitForExit();
                AppendLog(logPath, "exit_code=" + process.ExitCode);
                return process.ExitCode;
            }
        }
        catch (Exception ex)
        {
            AppendLog(logPath, "error=" + ex.GetType().Name + ": " + RedactLogValue(ex.Message));
            return 1;
        }
    }

    static string FindRealCodex()
    {
        string bestPath = null;
        string bestDirectoryName = null;
        Version bestVersion = null;

        using (RegistryKey packages = Registry.CurrentUser.OpenSubKey(PackageRegistryPath))
        {
            if (packages == null)
                throw new InvalidOperationException("The current-user AppX package registry is unavailable.");

            foreach (string packageName in packages.GetSubKeyNames())
            {
                if (!packageName.StartsWith(CodexPackagePrefix, StringComparison.OrdinalIgnoreCase)) continue;

                using (RegistryKey package = packages.OpenSubKey(packageName))
                {
                    string packageRoot = package == null ? null :
                        package.GetValue("PackageRootFolder", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
                    if (String.IsNullOrEmpty(packageRoot)) continue;

                    string executablePath = Path.Combine(packageRoot, CodexExecutableRelativePath);
                    if (!File.Exists(executablePath)) continue;

                    Version packageVersion = ParsePackageVersion(packageName);
                    bool isBetter = bestPath == null || packageVersion.CompareTo(bestVersion) > 0;
                    if (!isBetter && packageVersion.CompareTo(bestVersion) == 0 &&
                        string.Compare(packageName, bestDirectoryName, StringComparison.OrdinalIgnoreCase) > 0)
                        isBetter = true;

                    if (isBetter)
                    {
                        bestPath = executablePath;
                        bestDirectoryName = packageName;
                        bestVersion = packageVersion;
                    }
                }
            }
        }

        if (bestPath == null)
            throw new FileNotFoundException(
                "No registered OpenAI.Codex package containing app\\resources\\codex.exe was found.");

        return bestPath;
    }

    static Version ParsePackageVersion(string directoryName)
    {
        if (directoryName == null || !directoryName.StartsWith(CodexPackagePrefix, StringComparison.OrdinalIgnoreCase))
            return new Version(0, 0);

        string packageIdentity = directoryName.Substring(CodexPackagePrefix.Length);
        int architectureSeparator = packageIdentity.IndexOf('_');
        if (architectureSeparator <= 0) return new Version(0, 0);

        Version version;
        if (Version.TryParse(packageIdentity.Substring(0, architectureSeparator), out version))
            return version;
        return new Version(0, 0);
    }

    static string BuildArguments(string[] args)
    {
        var builder = new StringBuilder();
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) builder.Append(' ');
            builder.Append(QuoteArgument(args[i]));
        }
        return builder.ToString();
    }

    static string RedactArguments(string[] args)
    {
        var builder = new StringBuilder();
        bool redactNext = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (i > 0) builder.Append(' ');
            string argument = args[i] ?? "";
            if (redactNext)
            {
                builder.Append("<redacted>");
                redactNext = false;
                continue;
            }

            bool sensitiveOption = IsSensitiveOption(argument);
            if (sensitiveOption)
            {
                int separator = argument.IndexOf('=');
                if (separator >= 0)
                    builder.Append(argument.Substring(0, separator + 1)).Append("<redacted>");
                else
                {
                    builder.Append(QuoteArgument(argument));
                    redactNext = true;
                }
            }
            else
            {
                builder.Append(QuoteArgument(RedactLogValue(argument)));
            }
        }
        return builder.ToString();
    }

    static bool IsSensitiveOption(string value)
    {
        string lower = value.ToLowerInvariant();
        return lower == "--api-key" || lower == "--apikey" || lower == "--token" ||
            lower == "--password" || lower == "--secret" || lower.StartsWith("--api-key=") ||
            lower.StartsWith("--apikey=") || lower.StartsWith("--token=") ||
            lower.StartsWith("--password=") || lower.StartsWith("--secret=");
    }

    static string RedactLogValue(string value)
    {
        if (value == null) return "";
        string lower = value.ToLowerInvariant();
        if (lower.Contains("sk-") || lower.Contains("bearer ") || lower.Contains("api_key=") ||
            lower.Contains("apikey=") || lower.Contains("token="))
            return "<redacted>";

        const int maxLength = 256;
        if (value.Length > maxLength) return value.Substring(0, maxLength) + "...<truncated>";
        return value;
    }

    static void AppendLog(string path, string message)
    {
        File.AppendAllText(path, "[" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "] " + message + Environment.NewLine, Encoding.UTF8);
    }

    static string QuoteArgument(string value)
    {
        if (value == null || value.Length == 0) return "\"\"";

        bool needsQuotes = value.IndexOfAny(new char[] { ' ', '\t', '\n', '\r', '\"' }) >= 0;
        if (!needsQuotes) return value;

        var builder = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '\"')
            {
                builder.Append('\\', backslashes * 2 + 1);
                builder.Append('\"');
                backslashes = 0;
                continue;
            }

            builder.Append('\\', backslashes);
            builder.Append(character);
            backslashes = 0;
        }

        builder.Append('\\', backslashes * 2);
        builder.Append('\"');
        return builder.ToString();
    }
}
