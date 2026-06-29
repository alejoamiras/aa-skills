---
name: wallet-sdk
description: "Use when working with Aztec wallet integration, @aztec/wallet-sdk, wallet discovery, wallet connection, emoji verification, or capability manifests. Covers dApp frontend integration and wallet extension development."
---

Use the comprehensive reference in [wallet-sdk.md](wallet-sdk.md) for all wallet-sdk integration patterns, API reference, and React examples.

Key principles:
- Always use `WalletManager.configure()` + `getAvailableWallets()` for wallet discovery (not legacy injected globals)
- Always implement emoji verification via `hashToEmoji()` after `establishSecureChannel()`
- Always use `requestCapabilities(manifest)` to declare permissions upfront
- Always handle `provider.onDisconnect()` for unexpected disconnections
- Prefer `Contract.at(address, artifact, wallet)` + `.methods.fn().send()` over raw `wallet.sendTx()`
- Use `BatchCall` for multiple view/simulation calls
- Register contracts before interacting: `wallet.registerContract(instance, artifact)`
