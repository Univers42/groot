# Browser Flow Guide: ft_transcendence

Once `make all` and `docker compose up` complete, follow this guide to experience the full project through your browser.

## Prerequisites

- All Docker services running (verify with `docker compose ps`)
- System/browser trusts local CA (should be automatic from `make all`)
- No other services listening on ports 3001, 3002, 3003, 4322, 8787, 8000, 18200

## Quick Access URLs

| Service | URL | Purpose |
|---------|-----|---------|
| **Website** | https://localhost:4322 | Sign up / sign in |
| **osionos Editor** | https://localhost:3001 | Block editor (after bridge) |
| **Mail App** | https://localhost:3002 | Gmail integration (optional) |
| **Calendar App** | https://localhost:3003 | Google Calendar integration (optional) |
| **Auth Gateway** | https://localhost:8787/api/auth | Internal auth service |
| **BaaS Gateway** | https://localhost:8000 | Backend-as-a-Service |
| **Vault UI** | https://localhost:18200 | Secrets (dev only) |

---

## Complete Walkthrough

### 1️⃣ Open Website (`https://localhost:4322`)

**What you see:**
- opposite-osiris (Astro website)
- Marketing page with "Start free" button
- Navigation menu

**Actions:**
- Click "Start free" button
- Should redirect to signup/login form

---

### 2️⃣ Create Development Account

**Form:**
- **Email**: `testuser@example.com` (or any email)
- **Password**: `TestPassword123!` (or any password)
- **Confirm Password**: Same as above

**Important notes:**
- Email verification is **disabled** in dev mode
- Account is created immediately
- No confirmation email needed

**Next:** Form submits → creates account → auto-redirects to sign-in

---

### 3️⃣ Sign In

**Form:**
- **Email**: Use email from step 2
- **Password**: Use password from step 2

**What happens:**
- auth-gateway validates credentials
- Session token created (JWT)
- osionos_v1.* token stored in localStorage
- Browser stores osionos session metadata

**Next:** Sign in button → validation → automatic redirect with bridge token

---

### 4️⃣ Bridge Token Handoff (Automatic)

**Behind the scenes:**
1. Website calls `https://localhost:4000/api/auth/bridge/create`
2. Bridge API generates one-time token
3. Browser redirects to `https://localhost:3001/#bridge_token=...`
4. osionos-bridge validates token
5. Creates workspace entry in Postgres (`osionos_workspaces` table)
6. Stores workspace ID in session
7. Editor loads with populated state

**What you see:**
- Brief loading/transition
- osionos editor appears with workspace loaded

---

### 5️⃣ osionos Block Editor (`https://localhost:3001`)

**URL after bridge:**
```
https://localhost:3001/#source=adapter&view=v-prod-table
```

**What you see:**
- **Left sidebar**:
  - Workspace name (e.g., "testuser's osionos")
  - Navigation (pages, databases, etc.)
  - Mail icon (opens mail app)
  - Calendar icon (opens calendar app)
  - Settings icon
  - Logout button
  
- **Main editor area**:
  - Block canvas
  - Markdown/text input
  - Block formatting toolbar
  - Database/table views (if available)

**Your workspace:**
- Private to your account
- Persisted in Postgres
- Backed by BaaS data plane

---

### 6️⃣ Create Your First Document

**Step A: Type in editor**
```markdown
# Welcome to osionos

This is a **block editor** that supports:
- Markdown syntax
- Tables
- Code blocks
- Rich formatting
```

**Step B: Press Enter or Tab**
- Block editor parses markdown
- Creates block structure
- Transactions sent to osionos-bridge

**Behind the scenes:**
1. React editor captures input
2. MarkEngine parses markdown → AST
3. Canvas model updates
4. Transaction constructed: `{ op: 'insert', path: [...], value: {...} }`
5. Sent to `https://localhost:4000/api/txn`
6. osionos-bridge forwards to `https://localhost:8000/txn` (BaaS)
7. Kong routes to Rust data plane (or TS fallback during migration)
8. Database write with Postgres constraints
9. Workspace state updated
10. Browser refreshes view

**What you see:**
- Text appears as structured blocks
- Formatting applied
- Document saved (no explicit save button)

---

### 7️⃣ Create a Table (Optional)

**If available in UI:**
- Click "Insert" or `/table` slash command
- Table block appears
- Add rows/columns
- Data stored in `osionos_workspaces` schema

**Behind scenes:**
- Same transaction flow as documents
- BaaS handles table schema management
- Postgres constraints enforced

---

### 8️⃣ Open Mail App (Optional - Requires Gmail Setup)

**Click Mail icon in sidebar:**
- Opens `https://localhost:3002`
- Requires Gmail OAuth authorization
- First visit: prompts for Google login
- Subsequent visits: shows inbox

**Services involved:**
- **mail app** (React frontend)
- **mail-bridge** (TypeScript OAuth handler)
- **Google OAuth API** (external)
- **osionos-bridge** (session validation)

**Note:** If Gmail credentials not configured:
- Error message: "Gmail not configured"
- Can skip for now

---

### 9️⃣ Open Calendar App (Optional - Requires Google Calendar Setup)

**Click Calendar icon in sidebar:**
- Opens `https://localhost:3003`
- Requires Google Calendar OAuth authorization
- First visit: prompts for Google account
- Shows calendar events

**Services involved:**
- **calendar app** (React frontend)
- **calendar-bridge** (TypeScript OAuth handler)
- **Google Calendar API** (external)
- **osionos-bridge** (session validation)

**Note:** Can reuse Gmail credentials if both use same Google account

---

### 🔟 Settings & Account Management (Optional)

**Click Settings icon:**
- Account info
- Password change
- Workspace management
- Logout

**Logout flow:**
- Clears localStorage tokens
- Invalidates session in osionos-bridge
- Redirects to login page

---

## Verifying Everything Works

### ✅ Health Checks

```bash
# All services running?
docker compose ps

# Postgres workspace created?
docker compose exec -T postgres psql -U postgres -d postgres -c \
  "SELECT id, name FROM public.osionos_workspaces LIMIT 5;"

# Bridge session valid?
docker compose logs osionos-bridge | grep -i "token consumed\|workspace created"

# BaaS responding?
curl --cacert apps/baas/certs/track-binocle-local-ca.pem \
  https://localhost:8000/health
```

### 📊 Data Verification

**Check created workspace:**
```bash
docker compose exec -T postgres psql -U postgres -d postgres -c \
  "SELECT * FROM public.osionos_workspaces WHERE created_at > NOW() - INTERVAL '10 minutes';"
```

**Check transactions:**
```bash
docker compose logs osionos-bridge | grep -E "transaction|insert|update" | tail -20
```

**Check BaaS routing:**
```bash
docker compose logs kong | grep "txn\|gateway" | tail -20
```

---

## Common Issues & Fixes

### ❌ "Certificate Error" when opening https://localhost:4322

**Solution:**
- System didn't trust local CA
- Run: `make certs-trust-local`
- Restart browser (especially Firefox)
- Hard refresh: Ctrl+Shift+R (or Cmd+Shift+R on Mac)

### ❌ "Bridge token invalid" or "Workspace not created"

**Check:**
```bash
docker compose logs osionos-bridge | grep -i error | tail -10
docker compose logs postgres | grep -i error | tail -10
```

**Solution:**
- Restart bridge: `docker compose restart osionos-bridge`
- Clear browser localStorage: F12 → Application → Storage → Clear All
- Try sign-in again

### ❌ "BaaS gateway returned 502"

**Check:**
```bash
docker compose ps | grep -E "kong|baas"
docker compose logs kong | tail -50
```

**Solution:**
- Restart gateway: `docker compose restart kong`
- Check BaaS health: `make healthcheck`

### ❌ "Gmail app shows error"

**Expected:** Gmail OAuth requires credentials (optional for demo)
**Solution:** Skip mail/calendar testing or configure Gmail OAuth in `.env`

---

## What's Happening Behind the Scenes

### Architecture Tiers

```
┌─────────────────────────────────────────────────────────────┐
│ BROWSER (Your machine)                                      │
│ ├─ https://localhost:4322 (opposite-osiris website)         │
│ ├─ https://localhost:3001 (osionos editor)                  │
│ └─ https://localhost:3002, 3003 (mail, calendar)            │
└─────────────────────────────────────────────────────────────┘
                           ↓ HTTPS (local CA)
┌─────────────────────────────────────────────────────────────┐
│ DOCKER NETWORK (services)                                   │
│                                                             │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ APPLICATION TIER (TypeScript)                       │    │
│ │ ├─ opposite-osiris (Astro)                         │    │
│ │ ├─ osionos-app (React + Vite)                      │    │
│ │ ├─ osionos-bridge (auth + workspace)               │    │
│ │ ├─ mail (React)                                    │    │
│ │ ├─ calendar (React)                                │    │
│ │ └─ mini-baas (orchestration)                       │    │
│ └─────────────────────────────────────────────────────┘    │
│                         ↓                                    │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ CONTROL PLANE (Go)                                  │    │
│ │ ├─ auth-gateway (JWT validation)                   │    │
│ │ ├─ Kong (API routing)                              │    │
│ │ └─ postgrest (auto REST API)                       │    │
│ └─────────────────────────────────────────────────────┘    │
│                         ↓                                    │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ DATA PLANE (Rust - currently TS fallback)          │    │
│ │ ├─ Query execution                                 │    │
│ │ ├─ Transaction handling                            │    │
│ │ └─ Engine routing (PostgreSQL, MySQL, etc.)        │    │
│ └─────────────────────────────────────────────────────┘    │
│                         ↓                                    │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ PERSISTENCE (PostgreSQL 16)                         │    │
│ │ ├─ osionos_workspaces                              │    │
│ │ ├─ documents & blocks                              │    │
│ │ ├─ auth sessions                                   │    │
│ │ └─ application data                                │    │
│ └─────────────────────────────────────────────────────┘    │
│                                                             │
│ ┌─────────────────────────────────────────────────────┐    │
│ │ SUPPORTING SERVICES                                 │    │
│ │ ├─ Redis (sessions, pub/sub)                       │    │
│ │ ├─ Vault (secrets management)                      │    │
│ │ └─ Mailpit (dev email)                             │    │
│ └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### Key Transaction Path

When you type in osionos and the data persists:

```
1. Browser input event
   ↓
2. React component updates local state
   ↓
3. MarkEngine parses markdown → block AST
   ↓
4. Canvas model constructs transaction:
   {
     "op": "insert",
     "path": ["blocks", "0"],
     "value": { "type": "paragraph", "content": "..." }
   }
   ↓
5. osionos-bridge receives transaction
   ↓
6. Validates workspace session
   ↓
7. Forwards to https://localhost:8000/api/baas/txn
   ↓
8. Kong gateway routes to data plane
   ↓
9. Rust executor (or TS fallback) validates constraints
   ↓
10. PostgreSQL writes atomically (ACID guarantees)
    ↓
11. Response returned to browser
    ↓
12. React re-renders with persisted state
```

---

## Useful Browser DevTools

### 🌐 Network Tab
- Watch requests to `/api/auth`, `/api/txn`, `/api/graph`
- See response latencies
- Monitor WebSocket connections

### 💾 Application Tab
- View localStorage → `osionos_v1.*` token
- Check cookies (session IDs)
- Monitor IndexedDB (editor state cache)

### 📋 Console Tab
- `localStorage.getItem('osionos_v1.accessToken')` → see your token
- Network errors (CSP violations, CORS, etc.)
- React DevTools (if installed)

---

## Testing Complete Flow

```bash
# 1. All services up?
make healthcheck

# 2. Can reach website?
curl --cacert apps/baas/certs/track-binocle-local-ca.pem \
  https://localhost:4322 -I

# 3. Workspace created in DB?
docker compose exec -T postgres psql -U postgres -d postgres -c \
  "SELECT COUNT(*) FROM public.osionos_workspaces;"

# 4. osionos-bridge responding?
curl --cacert apps/baas/certs/track-binocle-local-ca.pem \
  https://localhost:4000/api/auth/bridge/health

# 5. View logs while using app
docker compose logs -f osionos-bridge osionos-app kong
```

---

## Next: Run Automated Verification

Once you've manually verified the flow, test with Playwright:

```bash
make playground
```

This runs the full automated scenario:
1. Opens website
2. Creates account
3. Signs in
4. Bridges into osionos
5. Creates document
6. Opens settings
7. Tests Mail and Calendar bridges
8. Verifies all endpoints respond

Check the result: success → `✅ All tests passed`

---

**Happy exploring! 🚀**

For issues or questions, see:
- `CLAUDE.md` — Complete architecture guide
- `wiki/TROUBLESHOOTING.md` — Common problems
- `wiki/SETUP.md` — Fresh clone checklist
