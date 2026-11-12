# Microsoft Store

## Restricted capability

The package declares `runFullTrust` and nothing else. Partner Center asks for a reason:

> Lazy Send is a desktop app built with .NET and WPF. It listens on the local network for a paired phone, sends and receives the files the user picks anywhere on the PC, reads photos from a phone plugged in by USB through Windows Portable Devices, and reads the state of Windows Firewall to say why a phone cannot connect. It does not need to be sandboxed to do this, and it has no other capability.

## Identity

Copy three values from Partner Center, Product identity, into the repository's Actions variables: Name as `STORE_IDENTITY_NAME`, Publisher as `STORE_PUBLISHER` and PublisherDisplayName as `STORE_PUBLISHER_DISPLAY_NAME`. Publish `x64` and `arm64` self-contained (`dotnet publish windows/LazySend.App/LazySend.App.csproj -c Release -r win-x64 --self-contained`) and build the upload on the PC with `scripts/make_msix.ps1`, giving the three values. Do not build it in CI: run artifacts of a public repository can be downloaded by any signed-in GitHub user. The Release workflow only checks that the package packs.
