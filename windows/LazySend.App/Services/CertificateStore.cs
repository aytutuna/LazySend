using LazySend.Core;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazySend.App.Services;

/// <summary>
/// The desktop's own certificate for the phone link: a self-signed ECDSA P-256 certificate in the
/// user's personal certificate store (CurrentUser\My, no administrator rights), with its private key
/// kept by Windows (CNG, persisted for this user). Phones pin its key (<see cref="SpkiFingerprint"/>),
/// so the certificate is renewed with the same key before it expires and every pin stays valid.
/// The key is never exported or written anywhere else. SChannel cannot serve TLS with an ephemeral key,
/// so the certificate is always loaded from the store (or after a PKCS#12 round trip that persists its key).
/// </summary>
public sealed class CertificateStore
{
    public const string FriendlyName = "Lazy Send phone link";
    /// <summary>How long a certificate is valid (Apple's limit for TLS server certificates).</summary>
    public static readonly TimeSpan Validity = TimeSpan.FromDays(825);
    /// <summary>A certificate is renewed (same key) when it has less than this left.</summary>
    public static readonly TimeSpan RenewBefore = TimeSpan.FromDays(60);

    private readonly object _gate = new();
    private X509Certificate2? _current;

    /// <summary>The certificate with its private key: the stored one, renewed or made on first use.</summary>
    public X509Certificate2 Current()
    {
        lock (_gate)
        {
            var now = DateTimeOffset.Now;
            if (_current is { } cached && cached.NotAfter > (now + RenewBefore).LocalDateTime) return cached;
            using var store = new X509Store("My", StoreLocation.CurrentUser);
            store.Open(OpenFlags.ReadWrite);
            var ours = Ours(store).OrderByDescending(c => c.NotAfter).ToList();
            var usable = ours.FirstOrDefault(HasUsableKey);
            X509Certificate2 certificate;
            if (usable is null)
            {
                certificate = Create(store, key: null, now);
            }
            else if (usable.NotAfter <= (now + RenewBefore).LocalDateTime)
            {
                using var key = usable.GetECDsaPrivateKey()!;
                certificate = Create(store, key, now);
            }
            else
            {
                certificate = usable;
            }
            // Older copies (and renewed ones) go; their key stays with the current one.
            foreach (var old in ours.Where(c => c.Thumbprint != certificate.Thumbprint)) RemoveKeepingKey(store, old, certificate);
            _current = certificate;
            return certificate;
        }
    }

    /// <summary>Whether the certificate's ECDSA private key can be opened (it may have been deleted).</summary>
    private static bool HasUsableKey(X509Certificate2 certificate)
    {
        if (!certificate.HasPrivateKey) return false;
        try
        {
            using var key = certificate.GetECDsaPrivateKey();
            return key is not null;
        }
        catch (CryptographicException)
        {
            return false;
        }
    }

    private static IEnumerable<X509Certificate2> Ours(X509Store store) =>
        store.Certificates.Cast<X509Certificate2>().Where(c => c.FriendlyName == FriendlyName);

    /// <summary>
    /// Makes a certificate for <paramref name="key"/> (a new persisted P-256 key when null) and adds
    /// it to the store; returns the store's copy, whose key SChannel can use.
    /// </summary>
    private X509Certificate2 Create(X509Store store, ECDsa? key, DateTimeOffset now)
    {
        ECDsa signing = key ?? NewPersistedKey();
        bool added = false;
        try
        {
            var request = new CertificateRequest($"CN={Environment.MachineName} Lazy Send", signing, HashAlgorithmName.SHA256);
            request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
            request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, true));
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.1")], false));
            request.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(request.PublicKey, false));
            using var created = request.CreateSelfSigned(now.AddDays(-1), now + Validity);
            // A certificate made from a persisted CNG key refers to it; added to the store, it keeps it.
            created.FriendlyName = FriendlyName;
            store.Add(created);
            added = true;
            return Ours(store).First(c => c.Thumbprint == created.Thumbprint);
        }
        catch when (key is null && !added)
        {
            // A new key whose certificate never reached the store is not left behind.
            DeleteNewKey(signing);
            throw;
        }
        finally
        {
            if (key is null) signing.Dispose();
        }
    }

    /// <summary>A new P-256 key that Windows keeps for this user under a name of its own.</summary>
    private static ECDsa NewPersistedKey()
    {
        var parameters = new CngKeyCreationParameters
        {
            ExportPolicy = CngExportPolicies.None,
            KeyCreationOptions = CngKeyCreationOptions.None,
            KeyUsage = CngKeyUsages.Signing,
        };
        var key = CngKey.Create(CngAlgorithm.ECDsaP256, "LazySend-" + Guid.NewGuid().ToString("N"), parameters);
        return new ECDsaCng(key);
    }

    /// <summary>Takes <paramref name="old"/> out of the store; its key is deleted unless <paramref name="current"/> uses it.</summary>
    private static void RemoveKeepingKey(X509Store store, X509Certificate2 old, X509Certificate2 current)
    {
        store.Remove(old);
        if (KeyName(old) is { } name && name != KeyName(current)) DeleteKey(old);
    }

    private static string? KeyName(X509Certificate2 certificate)
    {
        try
        {
            using var key = certificate.GetECDsaPrivateKey();
            return (key as ECDsaCng)?.Key.KeyName;
        }
        catch (CryptographicException)
        {
            return null;
        }
    }

    private static void DeleteNewKey(ECDsa key)
    {
        try
        {
            if (key is ECDsaCng cng && cng.Key.KeyName is not null) cng.Key.Delete();
        }
        catch (CryptographicException e)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not delete an unused phone link key: {e.Message}");
        }
    }

    private static void DeleteKey(X509Certificate2 certificate)
    {
        try
        {
            using var key = certificate.GetECDsaPrivateKey();
            if (key is ECDsaCng cng && cng.Key.KeyName is not null) cng.Key.Delete();
        }
        catch (CryptographicException e)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not delete an old phone link key: {e.Message}");
        }
    }
}
