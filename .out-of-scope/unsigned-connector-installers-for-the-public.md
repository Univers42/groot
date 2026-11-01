# Unsigned macOS and Windows Connector installers for the public are out of scope

- Decided: 2026-11-01 · by devil (ADR 0042, C-24)
- Holds while: osionos has no Apple Developer ID (with notarisation) and no Windows code-signing certificate

## The concept

Publish the macOS .pkg and the Windows .msi unsigned, and tell people how to get past the "unknown
publisher" warning, because the certificates cost money and need the owner's accounts.

## Why not

- A public page that teaches people to bypass Gatekeeper or SmartScreen for a program that grants a shell
  also teaches them to install a fake "osionos Connector". Without a signature, nobody can tell the two
  apart.
- The bypass is itself the extra steps the owner rejects ("without extra steps").
- Training memory, unverified here: macOS 15 moved the bypass to System Settings → Privacy & Security →
  Open Anyway.
- Named testers may still receive unsigned builds directly.

## Prior requests

- 2026-11-01 (plan, U5): unsigned until the owner buys the identities.

## Reopen when

Never for unsigned public builds. The point is settled once both signing identities exist and a signed,
notarised build passes Gatekeeper and SmartScreen without a prompt on a clean machine.
