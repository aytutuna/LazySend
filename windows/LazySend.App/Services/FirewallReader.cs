using System.Collections;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using LazySend.Core;

namespace LazySend.App.Services;

/// <summary>What Windows Defender Firewall's settings say about this app, read once.</summary>
public sealed record FirewallState(bool Read, FirewallProfiles CurrentProfiles, bool Enabled, IReadOnlyList<FirewallRule> Rules)
{
    public static FirewallState Unknown { get; } = new(false, FirewallProfiles.None, true, []);

    public FirewallVerdict Verdict(string applicationPath, int port) =>
        Read ? Firewall.Evaluate(Rules, applicationPath, CurrentProfiles, Enabled, port) : FirewallVerdict.Unknown;

    public IReadOnlyList<string> BlockingRules(string applicationPath) =>
        Read ? Firewall.BlockingRules(Rules, applicationPath, CurrentProfiles) : [];
}

/// <summary>
/// Reads Windows Defender Firewall's current profiles and its rules for one program through
/// HNetCfg.FwPolicy2 (COM, late bound, no administrator rights). It only reads: no rule is ever
/// added, changed or removed.
/// </summary>
public static class FirewallReader
{
    /// <summary>The firewall's state for <paramref name="applicationPath"/>; <see cref="FirewallState.Unknown"/> when it cannot be read. Never throws.</summary>
    public static FirewallState Read(string applicationPath, IReadOnlyList<string>? packageTokens = null)
    {
        object? policy = null;
        try
        {
            var type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2", throwOnError: false);
            if (type is null) return FirewallState.Unknown;
            policy = Activator.CreateInstance(type);
            if (policy is null) return FirewallState.Unknown;
            var profiles = (FirewallProfiles)Convert.ToInt32(Get(policy, "CurrentProfileTypes"), CultureInfo.InvariantCulture);
            var enabledProfiles = FirewallProfiles.None;
            foreach (var profile in new[] { FirewallProfiles.Domain, FirewallProfiles.Private, FirewallProfiles.Public })
            {
                if (Convert.ToBoolean(Get(policy, "FirewallEnabled", (int)profile), CultureInfo.InvariantCulture)) enabledProfiles |= profile;
            }
            var rules = new List<FirewallRule>();
            if (Get(policy, "Rules") is IEnumerable all)
            {
                foreach (object? rule in all)
                {
                    if (rule is null) continue;
                    try
                    {
                        string path = Get(rule, "ApplicationName") as string ?? "";
                        string name = Get(rule, "Name") as string ?? "";
                        bool own = string.Equals(Environment.ExpandEnvironmentVariables(path), applicationPath, StringComparison.OrdinalIgnoreCase);
                        // The rule a Store package declares names the package, not an exe path, which changes with every update.
                        bool package = !own && IsPackageRule($"{name} {Get(rule, "Grouping")}", packageTokens);
                        if (!own && !package) continue;
                        rules.Add(new FirewallRule(
                            name,
                            package ? applicationPath : path,
                            Convert.ToInt32(Get(rule, "Direction"), CultureInfo.InvariantCulture) == 1,
                            Convert.ToInt32(Get(rule, "Action"), CultureInfo.InvariantCulture) == 1,
                            Convert.ToBoolean(Get(rule, "Enabled"), CultureInfo.InvariantCulture),
                            (FirewallProfiles)Convert.ToInt32(Get(rule, "Profiles"), CultureInfo.InvariantCulture),
                            Convert.ToInt32(Get(rule, "Protocol"), CultureInfo.InvariantCulture),
                            Get(rule, "LocalPorts") as string ?? "*"));
                    }
                    finally
                    {
                        System.Runtime.InteropServices.Marshal.ReleaseComObject(rule);
                    }
                }
            }
            return new FirewallState(true, profiles, (enabledProfiles & profiles) != 0, rules);
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Could not read the firewall settings: {e.Message}");
            return FirewallState.Unknown;
        }
        finally
        {
            if (policy is not null) System.Runtime.InteropServices.Marshal.ReleaseComObject(policy);
        }
    }

    internal static bool IsPackageRule(string text, IReadOnlyList<string>? packageTokens) =>
        packageTokens is { Count: > 0 } && packageTokens.All(token => text.Contains(token, StringComparison.OrdinalIgnoreCase));

    private static object? Get(object target, string name, params object[] index) =>
        target.GetType().InvokeMember(name, BindingFlags.GetProperty, binder: null, target, index.Length == 0 ? null : index,
                                      CultureInfo.InvariantCulture);
}
