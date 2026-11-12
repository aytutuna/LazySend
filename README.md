# Lazy Send

Lazy Send moves text, links, files and whole photo galleries between a computer and a phone, in both directions, over the local network or a USB cable. The computer listens and the phone connects; the protocol is in CONTRACTS.md.

The source is available under the PolyForm Noncommercial License 1.0.0 (see LICENSE). It is source available, not open source.

The Windows app is in windows/ (LazySend.App and LazySend.Core), the Android app in android/ and the iPhone app in ios/ with its shared Swift package at the root (Sources/LazySendKit, Sources/LazySendIOS). To build and test the Windows part you need the .NET 10 SDK:

    dotnet test windows/LazySend.sln

Swift does not build on Windows, so the iPhone app is built and tested by the CI workflow on a macOS runner (`swift test` for LazySendKit, XcodeGen and xcodebuild for the app). On a Mac, `xcodegen generate --spec ios/project.yml` writes ios/LazySendiOS.xcodeproj.
