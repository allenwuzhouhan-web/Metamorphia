# Metamorphia licensing

Members-only activation using **Ed25519 signed license keys**.

- The app (`Metamorphia/Licensing/LicenseManager.swift`) embeds only the **public**
  verification key.
- License keys are signed with the **private** key, which lives only in
  `signing-key.b64` (gitignored) — never in the app.

A key is `base64(payload).base64(signature)` where `payload = "<licensee>|<id>"`.
At launch the app verifies the signature against the embedded public key; an
invalid or forged key fails and the app stays locked.

## Public key (embedded in the app)

```
am86LCGarP1xp/xeaU0x+UAl5oM7/k2b/ZaHgnOz8w8=
```

## Mint another key

```
cd licensing
xcrun swift mint-license-key.swift "Their Name"
```

Prints one token to stdout. Requires `signing-key.b64` (the private key) present,
or `$MM_SIGNING_KEY` set.

## What this guarantees (and what it doesn't)

- ✅ **Unforgeable** — a valid key can't be produced without the private key.
- ✅ **No extractable secret** — the app holds only the public key, so
  reverse-engineering the binary can't mint keys.
- ✅ **Traceable** — each key is bound to a licensee name.
- ⚠️ **Copyable** — a *legitimate* key string can still be shared between machines.
  Preventing that needs a server-side activation check (one activation per key),
  which is a separate build. A determined attacker can also patch any offline
  check out of the binary — true of all offline licensing.

## Keep the private key safe

`signing-key.b64` is gitignored. Store a backup somewhere safe (password manager
/ offline). If it leaks, rotate: generate a new keypair, replace the embedded
public key, ship an update, and re-issue keys.
