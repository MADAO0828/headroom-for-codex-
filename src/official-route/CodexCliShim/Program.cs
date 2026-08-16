using System.Diagnostics;
using System.Text.Json;

namespace CodexCliShim;

internal static class Program
{
    private const string GatewayBaseUrl = "http://127.0.0.1:18787/v1";
    private const string ShimMarker = "HEADROOM_SHIM_INJECTED";

    private static readonly string[] RuntimeOverrides =
    {
        "model_provider=headroom_runtime",
        "model_providers.headroom_runtime.base_url=\"http://127.0.0.1:18787/v1\"",
        "model_providers.headroom_runtime.wire_api=\"responses\"",
        "model_providers.headroom_runtime.requires_openai_auth=false",
        "model_providers.headroom_runtime.supports_websockets=false",
        "model_providers.headroom_runtime.env_key=\"HEADROOM_LOCAL_BEARER\"",
    };

    public static int Main(string[] args)
    {
        if (args.Any(arg => string.Equals(arg, "--headroom-shim-self-test", StringComparison.Ordinal)))
        {
            return SelfTest(args);
        }

        var realCliPath = ResolveRealCliPath();
        if (string.IsNullOrWhiteSpace(realCliPath))
        {
            Console.Error.WriteLine("route_a_real_cli_missing");
            return 78;
        }

        var realCli = Path.GetFullPath(realCliPath);
        var currentShim = Path.GetFullPath(Environment.ProcessPath ?? string.Empty);
        if (string.Equals(realCli, currentShim, StringComparison.OrdinalIgnoreCase))
        {
            Console.Error.WriteLine("route_a_shim_recursion");
            return 78;
        }

        var transformed = TransformArguments(args, IsAlreadyInjected());
        var startInfo = new ProcessStartInfo
        {
            FileName = realCli,
            UseShellExecute = false,
            WorkingDirectory = Environment.CurrentDirectory,
        };

        foreach (var argument in transformed)
        {
            startInfo.ArgumentList.Add(argument);
        }

        startInfo.Environment["CODEX_CLI_PATH"] = realCli;
        startInfo.Environment["CODEX_APP_SERVER_FORCE_CLI"] = "1";
        startInfo.Environment[ShimMarker] = "1";

        using var process = Process.Start(startInfo);
        if (process is null)
        {
            Console.Error.WriteLine("route_a_real_cli_start_failed");
            return 78;
        }

        process.WaitForExit();
        return process.ExitCode;
    }

    private static bool IsAlreadyInjected()
        => string.Equals(Environment.GetEnvironmentVariable(ShimMarker), "1", StringComparison.Ordinal);

    private static string? ResolveRealCliPath()
    {
        foreach (var variable in new[] { "HEADROOM_REAL_CODEX_CLI_PATH", "CODEX_CLI_REAL_PATH" })
        {
            var value = Environment.GetEnvironmentVariable(variable);
            if (!string.IsNullOrWhiteSpace(value) && File.Exists(value))
            {
                return value;
            }
        }

        return null;
    }

    internal static string[] TransformArguments(IReadOnlyList<string> args, bool alreadyInjected)
    {
        var original = args.ToList();
        var appServerIndex = original.FindIndex(arg => string.Equals(arg, "app-server", StringComparison.OrdinalIgnoreCase));
        if (alreadyInjected || appServerIndex < 0)
        {
            return original.ToArray();
        }

        var transformed = new List<string>(original.Count + RuntimeOverrides.Length * 2);
        transformed.AddRange(original.Take(appServerIndex));
        foreach (var overrideValue in RuntimeOverrides)
        {
            transformed.Add("-c");
            transformed.Add(overrideValue);
        }

        transformed.AddRange(original.Skip(appServerIndex));
        return transformed.ToArray();
    }

    private static int SelfTest(IReadOnlyList<string> rawArgs)
    {
        var args = rawArgs.Where(arg => !string.Equals(arg, "--headroom-shim-self-test", StringComparison.Ordinal)).ToArray();
        var transformed = TransformArguments(args, alreadyInjected: false);
        var document = new
        {
            schema = "route-a-shim-self-test/v1",
            gateway_base_url = GatewayBaseUrl,
            injected = transformed.Length != args.Length,
            original_arg_count = args.Length,
            transformed_arg_count = transformed.Length,
            transformed_args = transformed,
            config_write = false,
            settings_write = false,
            secrets_logged = false,
        };

        Console.WriteLine(JsonSerializer.Serialize(document));
        return 0;
    }
}
