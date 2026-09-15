# Osionos Cross-Browser Persistence Investigation Report

## Status

Investigation in progress.
No production code changes were made during this investigation.

This document summarizes:

* the original issue,
* the investigation process,
* confirmed runtime evidence,
* architectural findings,
* current hypotheses,
* unresolved unknowns,
* and recommended next investigation steps.

---

# 1. Original Problem Description

A user authenticated through the Prismatica landing/authentication flow experienced inconsistent page persistence between Firefox and Chromium.

Observed behavior:

* The same email/password account works in both browsers.
* User identity persists correctly across browsers.
* Pages created in Firefox are not visible in Chromium.
* Pages created in Chromium are not visible in Firefox.
* Chromium-created content persists even after clearing browser cache/history.
* The local Docker stack is identical for both browsers.

Initial suspicion focused on MongoDB persistence inconsistencies.

---

# 2. Investigation Goals

The original investigation aimed to determine:

1. Whether MongoDB was actually being used as the active persistence backend.
2. Whether browsers were connected to different workspaces.
3. Whether persistence was local-only or remote.
4. Whether Zustand/localStorage behavior caused browser divergence.
5. Whether session/bootstrap behavior differed between browsers.

---

# 3. Investigation Methodology

The investigation was intentionally performed in read-only mode.

No:

* code modifications,
* architectural changes,
* refactors,
* or persistence fixes

were introduced during the investigation.

The investigation combined:

* source code analysis,
* runtime tracing,
* local browser storage inspection,
* Kong/PostgREST log inspection,
* and direct PostgreSQL inspection.

---

# 4. Architecture Findings

## 4.1 Active Persistence Architecture

The active Osionos persistence path appears to be:

```text
Osionos Frontend
→ Bridge API
→ Kong
→ PostgREST
→ PostgreSQL
```

### Confirmed Components

Observed infrastructure:

* Bridge API
* Kong gateway
* PostgREST
* PostgreSQL tables:

  * `osionos_pages`
  * `osionos_workspaces`
  * `osionos_workspace_members`
  * `osionos_bridge_identities`

### Important Finding

MongoDB configuration exists in legacy/app-specific configuration paths, but runtime evidence strongly suggests MongoDB is NOT the active persistence backend currently used by Osionos.

Evidence:

* successful Postgres-backed page writes,
* successful Postgres-backed page reads,
* active bridge workspace resolution through PostgreSQL.

---

# 5. Source Code Findings

## 5.1 Local Persistence

The application stores multiple runtime artifacts in localStorage, including:

* bridge session
* user context
* workspace context
* cached pages
* Zustand persistence layers

Relevant localStorage patterns:

```text
osionos:bridge-session
osionos:user-context
osio:pages:<workspaceId>
pg:recents
```

---

## 5.2 Remote Persistence

Remote page persistence uses bridge API endpoints:

```text
GET    /api/pages/all
POST   /api/pages
PATCH  /api/pages/:id
DELETE /api/pages/:id
```

Persistence behavior is local-first / optimistic:

1. state updates locally,
2. local cache updates,
3. debounced PATCH persistence occurs later.

---

## 5.3 Merge Behavior

The page synchronization logic merges remote pages into existing cached pages.

Important implementation detail:

Cached pages missing from the remote response are retained locally instead of being discarded.

This means browser-local divergence is theoretically possible if:

* remote persistence fails,
* or stale local cache survives.

However, runtime evidence has not yet confirmed this as the primary root cause.

---

# 6. Runtime Investigation Findings

# 6.1 PostgreSQL Runtime State

Confirmed PostgreSQL workspace state:

```text
workspace id:
c455dd72-fdaa-431e-b3c1-cf76d0a1f2f5

owner/user id:
519b4cf2-f827-47f7-8c9b-edd4f86a1b8a
```

Confirmed:

* exactly one active Osionos bridge workspace exists,
* workspace membership is correct,
* workspace ownership is correct.

Bridge identity mapping confirms:

```text
Prismatica subject
→ stable workspace mapping
```

This significantly reduces the likelihood of:

* accidental multi-workspace divergence,
* or browser-created workspace duplication.

---

# 6.2 Chromium Runtime Findings

Chromium runtime evidence confirms:

## Workspace Identity

```text
active user id:
519b4cf2-f827-47f7-8c9b-edd4f86a1b8a

active workspace id:
c455dd72-fdaa-431e-b3c1-cf76d0a1f2f5
```

## Observed Cached Pages

```text
43274cb8-f9b3-4e52-bc03-95459031fd06
My chromium test

ae4fc30c-7df0-4607-b57b-5b7752e6415f
Notesssss

fd8b8c42-02e6-4ccf-af9e-280fcade8102
My Dashboard
```

## JWT Claims

Observed Prismatica authentication claims:

```text
sub:
519b4cf2-f827-47f7-8c9b-edd4f86a1b8a

iss:
https://localhost:8000/auth/v1

role:
authenticated
```

---

# 6.3 Firefox Runtime Findings

Firefox behavior remains partially unresolved.

Observed:

* Firefox history confirms access to:

  * `https://localhost:3001/`
* Firefox cookies exist:

  * `prismatica_refresh`
* Firefox localStorage inspection showed:

  * zero rows in `webappsstore.sqlite`

This is highly significant because source code strongly suggests the application SHOULD persist:

* bridge session,
* workspace state,
* page cache,
* and user context
  to localStorage.

At the time of investigation:

* Firefox workspace id was NOT confirmed,
* Firefox bridge token state was NOT confirmed,
* Firefox Osionos app token state was NOT confirmed.

---

# 6.4 Backend Runtime Persistence

Kong/PostgREST logs confirm successful remote persistence operations.

## Successful GET

```text
GET /rest/v1/osionos_pages?workspace_id=eq.c455dd72-fdaa-431e-b3c1-cf76d0a1f2f5
status: 200
```

Observed:

* 2026-05-28 11:02:44 UTC
* 2026-05-28 11:04:17 UTC

---

## Successful POST

```text
POST /rest/v1/osionos_pages
status: 201
```

Persisted page:

```text
43274cb8-f9b3-4e52-bc03-95459031fd06
"My chromium test"
```

---

## Successful PATCH

```text
PATCH /rest/v1/osionos_pages?id=eq.43274cb8-f9b3-4e52-bc03-95459031fd06
status: 200
```

Final persisted content:

* 5 paragraph blocks

---

# 7. Current Conclusions

## 7.1 Strongly Supported Conclusions

### A. MongoDB does not appear to be the active Osionos persistence backend

This is strongly supported by runtime evidence.

---

### B. Remote persistence is functioning correctly for Chromium

Confirmed:

* workspace resolution,
* page creation,
* page reads,
* page updates,
* PostgreSQL persistence.

---

### C. Workspace identity mapping appears stable

No evidence currently supports:

* browser-specific workspace creation,
* duplicate workspaces,
* or identity fragmentation.

---

### D. The issue likely exists in runtime bootstrap/session materialization

Current evidence increasingly suggests the issue is NOT:

* database persistence,
* workspace ownership,
* or backend write failures.

The most suspicious area is now:

```text
Prismatica auth
→ bridge handoff
→ Osionos session bootstrap
→ workspace hydration
→ local persistence materialization
```

Particularly in Firefox.

---

# 8. Current Hypotheses

## High Confidence

### Firefox bootstrap/session hydration failure

Potential symptoms:

* bridge token not consumed correctly,
* app token not persisted,
* workspace state not hydrated,
* transient/non-persistent runtime state.

---

## Medium Confidence

### Firefox storage restrictions/privacy behavior

Possibilities:

* partitioned localhost storage,
* ephemeral profile mode,
* browser storage policy interference,
* localStorage persistence failure.

---

## Medium Confidence

### Silent runtime exception during bootstrap

Potential:

* failed bridge session persistence,
* hydration interruption,
* token initialization failure.

---

## Lower Confidence

### Local cache merge policy as primary root cause

The merge behavior may amplify divergence, but runtime evidence has not yet confirmed it as the origin of the problem.

---

# 9. Important Unknowns

The following remain unresolved:

| Unknown                                                    | Status      |
| ---------------------------------------------------------- | ----------- |
| Does Firefox consume `bridge_token` correctly?             | Unconfirmed |
| Does Firefox persist `osionos:bridge-session`?             | Unconfirmed |
| Does Firefox obtain a valid Osionos app token?             | Unconfirmed |
| Does Firefox hydrate workspace state correctly?            | Unconfirmed |
| Are runtime exceptions occurring during Firefox bootstrap? | Unconfirmed |
| Are browser storage/security policies interfering?         | Unconfirmed |
| Is Firefox operating in transient/private storage mode?    | Unconfirmed |

---

# 10. Recommended Next Investigation Phase

The next investigation should focus exclusively on:

# Firefox Bootstrap Failure Localization

Recommended runtime tracing targets:

```text
Prismatica authentication
→ bridge token generation
→ redirect to Osionos
→ bridge token consumption
→ app token generation
→ workspace hydration
→ page fetch
→ local persistence
```

Required evidence collection:

* Firefox DevTools Console
* Firefox Network tab
* storage inspection
* runtime exceptions
* CSP warnings
* SameSite/cookie warnings
* failed storage operations
* redirect URL inspection
* bridge token presence
* authorization headers

---

# 11. Important Engineering Notes

At this stage, no implementation changes are recommended.

The investigation has:

* eliminated several incorrect hypotheses,
* narrowed the likely failure domain,
* and isolated the anomaly to runtime/bootstrap behavior rather than core persistence infrastructure.

Further debugging should prioritize:

* precise failure localization,
* runtime evidence collection,
* and browser bootstrap tracing

before any persistence or synchronization refactors are attempted.
