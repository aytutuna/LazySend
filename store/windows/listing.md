# Microsoft Store

## Restricted capability

The package declares `runFullTrust` and nothing else. Partner Center asks for a reason:

> Lazy Send is a desktop app built with .NET and WPF. It listens on the local network for a paired phone, sends and receives the files the user picks anywhere on the PC, reads photos from a phone plugged in by USB through Windows Portable Devices, and reads the state of Windows Firewall to say why a phone cannot connect. It does not need to be sandboxed to do this, and it has no other capability.

## Identity

Copy three values from Partner Center, Product identity, into the repository's Actions variables: Name as `STORE_IDENTITY_NAME`, Publisher as `STORE_PUBLISHER` and PublisherDisplayName as `STORE_PUBLISHER_DISPLAY_NAME`. Run the Release workflow and upload the `.msixupload` from its `lazysend-store` artifact.
