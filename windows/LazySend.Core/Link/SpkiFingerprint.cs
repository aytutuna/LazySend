using System.Buffers.Binary;
using System.Globalization;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace LazySend.Core;

/// <summary>
/// The fingerprint the phone pins the desktop's certificate by: the SHA-256 of the certificate's
/// SubjectPublicKeyInfo. It is the key that is pinned, not the certificate, so a renewed certificate
/// with the same key keeps every pin.
/// </summary>
public static class SpkiFingerprint
{
    public const int ByteCount = 32;

    public static byte[] Of(X509Certificate2 certificate) =>
        SHA256.HashData(certificate.PublicKey.ExportSubjectPublicKeyInfo());

    /// <summary>The fingerprint as the pairing code carries it: base64url without padding (43 characters).</summary>
    public static string Text(ReadOnlySpan<byte> fingerprint) => Protocol.EncodeBase64Url(fingerprint);

    public static bool Matches(ReadOnlySpan<byte> fingerprint, ReadOnlySpan<byte> expected) =>
        fingerprint.Length == ByteCount && expected.Length == ByteCount
        && CryptographicOperations.FixedTimeEquals(fingerprint, expected);

    /// <summary>
    /// The six-digit code people compare on the phone and the desktop: the fingerprint's first four
    /// bytes as a big-endian number modulo one million, with leading zeros; "" for fewer than four bytes.
    /// </summary>
    public static string CheckCode(ReadOnlySpan<byte> fingerprint)
    {
        if (fingerprint.Length < 4) return "";
        uint value = BinaryPrimitives.ReadUInt32BigEndian(fingerprint);
        return (value % 1_000_000).ToString("D6", CultureInfo.InvariantCulture);
    }
}

/// <summary>The desktop's certificate: self-signed, ECDSA P-256, valid for ten years. Keeping it between runs is the app's job.</summary>
public static class SelfSignedCertificate
{
    public static X509Certificate2 Create(string machineName)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest($"CN={machineName} Lazy Send", key, HashAlgorithmName.SHA256);
        request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature, critical: true));
        request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid("1.3.6.1.5.5.7.3.1")], critical: false));
        var now = DateTimeOffset.UtcNow;
        using var certificate = request.CreateSelfSigned(now.AddDays(-1), now.AddYears(10));
        // Reloaded from PFX so the private key is usable by SslStream on Windows.
        return X509CertificateLoader.LoadPkcs12(certificate.Export(X509ContentType.Pfx), null, X509KeyStorageFlags.Exportable);
    }
}
