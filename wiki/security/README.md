# Security Documentation

HashiCorp Vault architecture, credential types, session management, and recovery procedures for Track Binocle.

---

## Vault Guides

| Document | Audience | When to read |
|----------|----------|-------------|
| [vault-admin-seed-retrieval.md](vault-admin-seed-retrieval.md) | Admin / owner | Fresh machine setup, "refusing localhost" error, first-time Fly token wiring |
| [vault-session-management.md](vault-session-management.md) | Admin / owner | Day-to-day session login, token minting, logout |
| [vault-fly-admin-setup.md](vault-fly-admin-setup.md) | Admin / owner | Quick fix for localhost token error |
| [vault-publish-from-home.md](vault-publish-from-home.md) | Admin / owner | Publishing updated secrets to the Fly Vault |
| [vault-owner-recovery-and-invite.md](vault-owner-recovery-and-invite.md) | Admin / owner | Lost admin credentials, owner boundary, reset path |

## Security Model

| Document | Audience | When to read |
|----------|----------|-------------|
| [../vault-security-model.md](../vault-security-model.md) | Everyone | Understanding token TTLs, policies, and why localhost tokens are rejected |

## Quick Decision Tree

```
I need to run make all on a new machine
└── Do I have .vault/track-binocle-reader.env?
    ├── YES → does it say VAULT_ADDR=https://track-binocle-vault.fly.dev?
    │   ├── YES → make vault-shared-doctor, then make all
    │   └── NO  → it points to localhost → see vault-admin-seed-retrieval.md
    └── NO  → am I a teammate or an admin?
        ├── TEAMMATE → get the reader token file from the maintainer, chmod 600 it
        └── ADMIN    → see vault-admin-seed-retrieval.md (need FLY_API_TOKEN)
```
