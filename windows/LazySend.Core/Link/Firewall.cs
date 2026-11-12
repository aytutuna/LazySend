namespace LazySend.Core;

/// <summary>Firewall profiles (NET_FW_PROFILE_TYPE2), as a bit mask.</summary>
[Flags]
public enum FirewallProfiles
{
    None = 0,
    Domain = 1,
    Private = 2,
    Public = 4,
    All = 0x7FFFFFFF,
}

/// <summary>One firewall rule, as the app reads it from Windows Defender Firewall.</summary>
/// <param name="ApplicationPath">The program it applies to; "" for a rule for every program.</param>
/// <param name="Protocol">NET_FW_IP_PROTOCOL: 6 TCP, 17 UDP, 256 any.</param>
/// <param name="LocalPorts">"*", "52734", "5000-5100,6000"; "" counts as any.</param>
public sealed record FirewallRule(string Name, string ApplicationPath, bool Inbound, bool Allow, bool Enabled,
                                  FirewallProfiles Profiles, int Protocol, string LocalPorts);

public enum FirewallVerdict
{
    /// <summary>The rules could not be read.</summary>
    Unknown,
    Off,
    Allowed,
    /// <summary>A rule blocks the app (often from a cancelled firewall prompt).</summary>
    Blocked,
    /// <summary>No rule for the app yet: Windows asks the first time the app listens.</summary>
    WillAsk,
}

/// <summary>What the firewall's rules mean for phones connecting to the app. The app reads the rules; the decision is here so it can be tested.</summary>
public static class Firewall
{
    public const int ProtocolTcp = 6;
    public const int ProtocolAny = 256;

    /// <summary>
    /// The verdict for the program at <paramref name="applicationPath"/> listening on <paramref name="port"/>:
    /// an enabled inbound rule for it, on one of <paramref name="profiles"/>, for TCP or any protocol and a
    /// port range holding the port, blocks (a block rule wins, as in Windows) or allows; without one the
    /// firewall asks, unless it is off.
    /// </summary>
    public static FirewallVerdict Evaluate(IReadOnlyList<FirewallRule> rules, string applicationPath, FirewallProfiles profiles,
                                           bool firewallEnabled, int port)
    {
        if (!firewallEnabled) return FirewallVerdict.Off;
        var relevant = rules.Where(rule => rule.Enabled && rule.Inbound && (rule.Profiles & profiles) != 0
                                           && SamePath(rule.ApplicationPath, applicationPath)
                                           && rule.Protocol is ProtocolTcp or ProtocolAny
                                           && PortMatches(rule.LocalPorts, port)).ToList();
        if (relevant.Any(rule => !rule.Allow)) return FirewallVerdict.Blocked;
        if (relevant.Any(rule => rule.Allow)) return FirewallVerdict.Allowed;
        return FirewallVerdict.WillAsk;
    }

    /// <summary>The names of the enabled inbound rules that block the program on <paramref name="profiles"/>.</summary>
    public static IReadOnlyList<string> BlockingRules(IReadOnlyList<FirewallRule> rules, string applicationPath,
                                                      FirewallProfiles profiles = FirewallProfiles.All) =>
        [.. rules.Where(rule => rule.Enabled && rule.Inbound && !rule.Allow && (rule.Profiles & profiles) != 0
                                && SamePath(rule.ApplicationPath, applicationPath))
                 .Select(rule => rule.Name).Distinct()];

    /// <summary>Whether a rule's local ports ("*", "", "80", "5000-5100", lists of those) include <paramref name="port"/>.</summary>
    public static bool PortMatches(string localPorts, int port)
    {
        string ports = localPorts.Trim();
        if (ports.Length == 0 || ports == "*") return true;
        foreach (string part in ports.Split(','))
        {
            string item = part.Trim();
            int dash = item.IndexOf('-');
            if (dash > 0 && int.TryParse(item[..dash], out int low) && int.TryParse(item[(dash + 1)..], out int high))
            {
                if (port >= low && port <= high) return true;
            }
            else if (int.TryParse(item, out int single) && single == port)
            {
                return true;
            }
        }
        return false;
    }

    private static bool SamePath(string rulePath, string applicationPath)
    {
        if (rulePath.Length == 0 || applicationPath.Length == 0) return false;
        string a = Environment.ExpandEnvironmentVariables(rulePath).Trim().Trim('"');
        string b = applicationPath.Trim().Trim('"');
        return string.Equals(a, b, StringComparison.OrdinalIgnoreCase);
    }
}
