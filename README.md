# Lazy Send

Lazy Send moves text, links, files and whole photo galleries between a computer and a phone, in both directions, over the local network or a USB cable. The computer listens and the phone connects; the protocol is in CONTRACTS.md.

The source is available under the PolyForm Noncommercial License 1.0.0 (see LICENSE). It is source available, not open source.

Only the Windows app and its core library exist so far (windows/LazySend.App and windows/LazySend.Core). To build and test them you need the .NET 10 SDK:

    dotnet test windows/LazySend.sln
