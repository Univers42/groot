# Backend security — référence stack

Toute la sécurité backend est mise en place pour fonctionner **100 % via
Docker** côté local. Aucun scanner ne suppose une installation host. Si tu
as `docker` (et `make` pour les wrappers), tu peux tout lancer.

## Vue d'ensemble — défense en profondeur

```
┌─────────────────────────────────────────────────────────────────────┐
│  Internet / client                                                  │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  WAF — nginx + ModSecurity + OWASP CRS 4                            │
│  • SQLi / XSS / scanner detection                                   │
│  • TLS terminaison (cert local en dev)                              │
│  • Reverse-proxy vers Kong                                          │
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Kong — API gateway (DB-less YAML)                                  │
│  • JWT validation (HS256 secret venu de Vault)                      │
│  • Rate-limiting (300/min auth, 180/min rest, 120/min realtime)     │
│  • CORS strict (origines whitelistées)                              │
│  • Response headers (HSTS, X-CTO, X-FO, Referrer-Policy)            │
│  • Inject X-User-Id / X-User-Email / X-User-Role en headers internes│
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Services NestJS                                                    │
│  • AuthGuard (lit X-User-Id depuis Kong)                            │
│  • RolesGuard + ABAC (Map<role, IDatabaseAdapter>)                  │
│  • Zod + class-validator (whitelist:true, forbidNonWhitelisted:true)│
│  • AuditInterceptor → audit_log (request_id, actor, action, payload)│
└──────────────────────────────┬──────────────────────────────────────┘
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Données                                                            │
│  • PostgreSQL RLS (auth.uid() = owner_id)                           │
│  • MongoDB owner_id auto-injected via mongo-api                     │
│  • Credentials externes chiffrés AES-256-GCM + scrypt               │
│  • Vault pour JWT_SECRET, OAuth, SMTP (jamais en clair en git)      │
└─────────────────────────────────────────────────────────────────────┘
```

## Stack scanner — comment tout tourne localement

Une seule commande lance tout :

```bash
make baas-security-scan
```

Détaille les 4 scanners qu'elle enchaîne :

### 1. SAST — Semgrep

**Quoi** : analyse statique du code TypeScript / Dockerfile / YAML
contre les rules OWASP Top 10, TypeScript, Dockerfile, Node.js, JavaScript.

**Comment** : conteneur `returntocorp/semgrep:latest`, sources montées
read-only.

**Sortie** : [`artifacts/security/semgrep.json`](../../apps/baas/mini-baas-infra/artifacts/security/)

**Critère de blocage** : ≥ 1 finding `ERROR` → exit 1. Les `WARNING` sont
logguées mais non bloquantes (à toi d'arbitrer).

```bash
# Lancer Semgrep seul
make baas-security-scan SECURITY_ONLY=semgrep

# Avec un pack de rules différent
SECURITY_SEMGREP_CONFIG="p/owasp-top-ten p/nodejs" \
  make baas-security-scan SECURITY_ONLY=semgrep
```

### 2. SCA — npm + pnpm audit

**Quoi** : audit des `package-lock.json` et `pnpm-lock.yaml` de chaque
workspace contre les CVE des dépendances.

**Comment** : conteneur `node:20-alpine`, chaque workspace audité indépendamment.

**Workspaces couverts** :

| Workspace | Outil |
|---|---|
| `apps/baas/mini-baas-infra/src` | npm |
| `apps/baas/sdk` | npm |
| `apps/baas/scripts` | npm |
| `apps/opposite-osiris` | npm |
| `apps/calendar` | npm |
| `apps/mail` | npm |
| `apps/osionos/app` | pnpm |

**Critère de blocage** : ≥ 1 workspace avec vulns ≥ `high` (configurable via
`SECURITY_FAIL_LEVEL`) → exit 1.

```bash
# Bloquer aussi sur moderate
SECURITY_FAIL_LEVEL=moderate make baas-security-scan SECURITY_ONLY=npm-audit
```

### 3. Container — Trivy

**Quoi** : deux scans complémentaires.
- **fs scan** : Dockerfile misconfigs + dep tree CVEs sans avoir besoin
  des images buildées.
- **image scan** : sur chaque image `mini-baas-*` présente sur l'host.

**Comment** : conteneur `aquasec/trivy:latest`, monte `/var/run/docker.sock`
en lecture pour le scan d'images.

**Sortie** : [`artifacts/security/trivy/`](../../apps/baas/mini-baas-infra/artifacts/security/trivy/)

**Critère de blocage** : ≥ 1 vuln `HIGH` ou `CRITICAL` ignore-unfixed=false
→ exit 1 (configurable via `SECURITY_TRIVY_SEVERITY`).

```bash
# Strictement critical
SECURITY_TRIVY_SEVERITY=CRITICAL make baas-security-scan SECURITY_ONLY=trivy

# Skipper le scan d'images (juste fs)
SKIP_BUILD=1 make baas-security-scan SECURITY_ONLY=trivy
```

### 4. Secret — TruffleHog

**Quoi** : scan de tout l'historique git pour détecter des secrets
**vérifiés** (clés API, tokens, credentials qui sont encore valides).

**Comment** : conteneur `trufflesecurity/trufflehog:latest`, repo monté
read-only.

**Sortie** : [`artifacts/security/trufflehog.json`](../../apps/baas/mini-baas-infra/artifacts/security/)

**Critère de blocage** : ≥ 1 secret vérifié → exit 1.

```bash
make baas-security-scan SECURITY_ONLY=trufflehog
```

**Important** : `--only-verified` veut dire que TruffleHog teste activement
si la clé est encore utilisable (ex. fait un call API contre Slack/AWS/etc.).
Une clé trouvée → c'est une vraie urgence : il faut révoquer immédiatement.

### 5. DAST — OWASP ZAP baseline

**Quoi** : scan dynamique contre le WAF live. Crawle l'application,
identifie les vulns observables sans authentification.

**Comment** : conteneur `zaproxy/zap-stable:latest`, target HTTPS via le
WAF (par défaut `https://127.0.0.1:18443`).

**Prérequis** : stack up (`make baas-up`).

```bash
# Stack up puis ZAP
BAAS_VERIFY_SAFE_PORTS=1 make baas-up
BAAS_VERIFY_SAFE_PORTS=1 make baas-zap
```

**Sortie** : 3 formats dans [`artifacts/security/`](../../apps/baas/mini-baas-infra/artifacts/security/) :
- `zap-baseline.json` (machine-readable)
- `zap-baseline.html` (visual report)
- `zap-baseline.md` (résumé markdown)

**Critère de blocage** : ≥ 1 finding `High` (riskcode 3) → exit 1. Les
findings `Medium` sont logguées mais non bloquantes.

## Vault — gestion des secrets

| Secret | Source | Consommateurs |
|---|---|---|
| `JWT_SECRET` | Vault (généré au démarrage) | GoTrue, Kong |
| OAuth (Google/Gmail) | Vault | calendar bridge, mail bridge |
| SMTP credentials | Vault | email-service, GoTrue |
| Master encryption key (AES-256) | Vault | adapter-registry (chiffre les credentials de DB externes) |
| PostgreSQL admin | docker-compose `.env` (overridable par Vault) | postgres, postgrest |

**Récupération partagée** : pour qu'un coéquipier ait les mêmes secrets sans
qu'ils transitent par message :
- Mainteneur génère un token reader via `make vault-fly-invite-token VAULT_TEAM_ROLE=reader`.
- Le développeur place le token dans `.vault/track-binocle-reader.env` (ignoré
  par git, chmod 600).
- `make all` contacte le Vault partagé Fly.io, récupère uniquement ce que la
  policy du token autorise, écrit les `.env` locaux.

## CI — GitHub Actions

Le workflow [`mini-baas-security.yml`](../../.github/workflows/mini-baas-security.yml)
orchestre **7 jobs** sur chaque PR + push main :

| Job | Outil | Quand bloque |
|---|---|---|
| `sast-semgrep` | Semgrep + SARIF upload | findings ERROR |
| `sca-npm-audit` (matrix par workspace) | npm/pnpm audit | vuln ≥ high |
| `sca-snyk` | Snyk | vuln ≥ high (gated sur token) |
| `container-trivy` | Trivy fs + image | vuln HIGH/CRITICAL |
| `secret-trufflehog` | TruffleHog | verified secret found |
| `dast-zap` (push main only) | ZAP baseline | finding High |
| `security-gate` | Agrégateur | any of above failed |

Les SARIF sont uploadés dans l'onglet **Security** de GitHub (Code scanning
alerts). Les artifacts ZAP sont téléchargeables depuis l'exécution.

## Pre-commit local (optionnel mais recommandé)

Pour bloquer les secrets avant qu'ils n'atteignent git :

```bash
# Install pre-commit hook qui exécute TruffleHog sur la diff
cat > .git/hooks/pre-commit <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
docker run --rm -v "$(pwd):/repo" trufflesecurity/trufflehog:latest \
  git file:///repo \
    --since-commit HEAD \
    --only-verified \
    --fail
EOF
chmod +x .git/hooks/pre-commit
```

## Dette résiduelle (à durcir)

- **Snyk** : intégration CI conditionnelle sur `${{ secrets.SNYK_TOKEN }}`.
  Configure le secret dans Settings → Secrets → Actions si tu veux l'activer.
- **Trivy ignore policy** : pas de `.trivyignore` aujourd'hui. À créer si
  certains CVEs ne peuvent pas être patchés (transitive deps, etc.).
- **Semgrep custom rules** : aujourd'hui on utilise uniquement les rule packs
  communautaires. Pour des règles spécifiques au projet (ex. interdire
  l'usage de `JSON.parse` sur input non validé), créer
  `.semgrep/custom-rules.yml`.
- **ZAP Authenticated scan** : la baseline scan ne touche que les routes
  publiques. Pour scanner les routes authentifiées, configurer le ZAP context
  avec un JWT (voir [ZAP authentication docs](https://www.zaproxy.org/docs/desktop/start/features/authentication/)).
- **SBOM (Software Bill of Materials)** : Trivy peut générer un SBOM CycloneDX
  via `trivy image --format cyclonedx`. À automatiser en CI pour la
  conformité supply-chain.
