# opposite-osiris — site, auth and the bridge

> **Status:** Partial · 2026-09-15
> **Evidence:** routing and the bridge handoff described in the submodule's own README;
> `website.json` is one of the two contracts provisioned on every production boot
> **To check:** whether the Privacy Policy and Terms of Service pages exist here, are reachable
> from the UI and carry real content. **This is a rejection criterion for the evaluation.**
> **Sources:** `apps/opposite-osiris/README.md` · `infra/config/contracts/website.json`

The public face: marketing site, sign-up and sign-in, and the handoff into the editor. Built
with Astro.

**Naming, because it trips everyone.** The submodule lives at `apps/opposite-osiris/`, its own
README is titled `opposite-osiris`, and the repository it clones from is
`Univers42/prismatica`. A rename that never fully propagated. Nothing is missing.
→ [04-repos](04-repos.md)

---

## How it is wired

Two proxy paths, and the split is the architecture in miniature:

```
/api/auth  →  auth-gateway   (sessions, sign-in, sign-up)
/api       →  Kong           (everything else: data, storage, realtime)
```

Authentication goes to the gateway; data goes through the BaaS door. The site holds no state of
its own — that boundary is declared binding.
→ [operations/03-deployment](../operations/03-deployment.md)

---

## The bridge

A successful login does not redirect with a token in a query string. It creates a **bridge
session** and hands the user to osionos, which consumes it at
`/api/auth/bridge/consume` on the bridge service (`:4000`).

The handoff URL carries the editor's opening state:

```
#source=adapter&view=v-prod-table
```

Two products, one identity, and the seam between them is a single consumable session rather than
a shared secret. → [02-osionos](02-osionos.md)

---

## It is a contract, not code

`website.json` is one of the two contracts provisioned on every production boot. Read it and you
have the whole application: its database, its isolation strategy, its roles, its permissions, its
API keys, and the `PUBLIC_*` variables the Astro build consumes.

```json
"mounts": [{ "name": "website-pg", "engine": "postgresql",
             "isolation": "shared_rls", "read_scoped": true }],
"frontend_config": { "path": "build/website.env", "vars": {
    "PUBLIC_GROBASE_URL": "${KONG_URL}", "PUBLIC_BAAS_KEY": "${ANON_KEY}" }}
```

The site's environment is **emitted by the provisioner**, never written by hand.
→ [platform/06-contracts](../platform/06-contracts.md)

Its database and vault42's are the two that prove per-user `read_scoped` isolation over public
HTTPS — not in a test, in production. → [security/02-proofs](../security/02-proofs.md)

---

## Authentication available here

Email and password with hashed, salted storage is the baseline. **Email OTP is enabled in
production** with real SMTP, so a full sign-up reaches a real inbox — worth using in a
demonstration rather than a screenshot.

Off by default and therefore not currently demonstrable: SSO/OIDC (`SSO_ENABLED`), passkeys
(`PASSKEYS_ENABLED`). → [operations/02-flags](../operations/02-flags.md)

---

## The rejection criterion that lives here

The subject requires a **Privacy Policy** and **Terms of Service**, reachable from the
application, with real content, not placeholders. Their absence or inadequacy causes outright
rejection of the project.

They belong on this site — footer links, two pages. Nothing in the documentation we have
confirms they exist. It is the cheapest risk in the whole evaluation to eliminate and it has not
been checked. → [DEFENSE.md](../DEFENSE.md)

---

See also: [01-apps](01-apps.md) · [02-osionos](02-osionos.md) ·
[project/02-modules](../project/02-modules.md)
