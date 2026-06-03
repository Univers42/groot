# Backend — index documentation

Ce dossier regroupe la documentation **opérationnelle** du backend
`mini-baas-infra` : ce qu'il contient, comment il est structuré, ce qui a
été livré dans chaque jalon, et comment vérifier que tout fonctionne.

| Fichier | À lire quand |
|---|---|
| [commands.md](./commands.md) | Tu veux la **référence exhaustive** de toutes les commandes (make targets, healthchecks, verify scripts, scanner suite) avec leur contexte d'usage. |
| [CHANGELOG.md](./CHANGELOG.md) | Tu veux la liste chronologique de **tous les changements** apportés au backend (M1 → M5 + sécurité + restore d'urgence). |
| [milestones.md](./milestones.md) | Tu veux savoir **où en est chaque jalon** (M1 à M5) : livré, partiel, en dette. |
| [security.md](./security.md) | Tu veux comprendre la **stack sécurité** (Semgrep, npm audit, Trivy, TruffleHog, ZAP, WAF, Vault) et comment l'invoquer. |
| [verify-and-test.md](./verify-and-test.md) | Tu veux **lancer les gates** (M1-M5, scanner suite, ZAP) en local ou en CI. |
| [agnostic-report.md](./agnostic-report.md) | Tu veux le **rapport de vérification** prouvant que le BaaS est 10/10 agnostique (sortie brute des 51 assertions de `make baas-verify-all`). |
| [agnostic-vs-incumbents.md](./agnostic-vs-incumbents.md) | Tu veux savoir si ce BaaS est *vraiment* agnostique et **en quoi il diffère** de Supabase, Firebase, Appwrite, PocketBase. |
| [agnostic_back.md](./agnostic_back.md) | Note de design originelle : comment lire/écrire dans n'importe quelle DB. C'est l'intention qui a guidé M2 (fédération). |
| [agent-prompt-agnostic-baas.md](./agent-prompt-agnostic-baas.md) | Prompt d'ingénierie pour les jalons **M6-M10** (FDW, adapters étendus, saga généralisé, ABAC central, SDK codegen). |
| [secure-baas-product-roadmap.md](./secure-baas-product-roadmap.md) | Roadmap critique pour transformer le backend actuel en **vrai produit BaaS multi-tenant** : trust boundary, tenancy, adapter SPI, ACID par moteur, saga, ABAC, realtime et modules. |
| [secure-baas-trust-boundary.md](./secure-baas-trust-boundary.md) | Design de frontière de confiance : headers signés par Kong, service tokens scopés, mTLS/JWT, rejet des headers forgés. |
| [secure-baas-tenancy-isolation.md](./secure-baas-tenancy-isolation.md) | Modèle tenant/project/app/user, isolation par plan, BYO DB, quotas, tenant keys. |
| [secure-baas-adapter-spi.md](./secure-baas-adapter-spi.md) | SPI hexagonal des drivers, pool registry, mounts, capability matrix et suppression du coût connexion par requête. |
| [secure-baas-transactions-acid-saga.md](./secure-baas-transactions-acid-saga.md) | Transaction sessions HTTP, ACID par moteur, limite 2PC, saga/outbox pour cross-engine. |
| [secure-baas-abac-pdp-rls.md](./secure-baas-abac-pdp-rls.md) | ABAC comme gate obligatoire, PDP local cache, RLS en defense-in-depth, policy bundles. |
| [secure-baas-realtime-event-plane.md](./secure-baas-realtime-event-plane.md) | Realtime multi-tenant/multi-app : topics namespacés, ACL, replay, quotas, outbox durable. |
| [secure-baas-module-system.md](./secure-baas-module-system.md) | Kernel de sécurité non désactivable + manifests de modules pour générer Kong/Compose/capabilities. |
| [secure-baas-verification-plan.md](./secure-baas-verification-plan.md) | Gates M11-M17 et plan de migration pour prouver les garanties produit. |
| [secure-baas-runtime-migration.md](./secure-baas-runtime-migration.md) | Stratégie TypeScript/Go/Rust : TypeScript pour la surface produit, Go pour le control plane, Rust pour le data plane, avec migration progressive. |
| [services/](../../apps/baas/mini-baas-infra/src/apps/) | README détaillé de chacun des 14 microservices NestJS (endpoints, comment les invoquer depuis SDK / Kong / `docker exec`). |

## TL;DR — état actuel

- **5 jalons définis** : M1 hardening, M2 federation, M3 coherence, M4 observability, M5 security.
- **Gates verts en static** sur M1, M2, M3, M4, M5 — chaque jalon a son script `scripts/verify/mX-*.sh` qui exit 0.
- **Gates live** (avec `--live`) : M1, M2, M3, M5 ont des probes runtime ; M4 a un check soft (PrometheusModule pas encore `register()` dans les app.module.ts).
- **5 engines** branchés au query-router : `postgresql`, `mongodb`, `mysql`, `redis`, `http` (tous implements `IDatabaseAdapter`).
- **Stack sécurité** complète, 100 % Docker (zéro install host) : SAST Semgrep, SCA npm/pnpm audit, Container Trivy, Secret TruffleHog, DAST ZAP.
- **CI** : `.github/workflows/mini-baas-security.yml` (7 jobs) qui orchestre tout sur chaque PR + push main.

## Commandes essentielles

```bash
# Bring up the stack (safe ports, no WAF for quick smoke)
BAAS_VERIFY_SAFE_PORTS=1 BAAS_VERIFY_NO_WAF=1 make baas-up

# Run every milestone gate in static mode (no live probes)
make baas-verify-all

# Run every milestone gate live (stack must be up first)
BAAS_VERIFY_LIVE=1 BAAS_VERIFY_SAFE_PORTS=1 make baas-verify-all

# Run the full security scanner suite (SAST + SCA + Container + Secret)
make baas-security-scan

# Run only one scanner
make baas-security-scan SECURITY_ONLY=semgrep
make baas-security-scan SECURITY_ONLY=trivy
make baas-security-scan SECURITY_ONLY=trufflehog

# DAST baseline (needs WAF up, https://localhost:18443)
BAAS_VERIFY_SAFE_PORTS=1 make baas-zap

# Tear down (volumes wiped)
make baas-down
```

## Conventions

- **Tout passe par Docker.** Aucun script ne suppose npm/node/pg/redis-cli/etc.
  installés sur le host. Si tu as Docker, tu peux tout lancer.
- **Les scripts `scripts/verify/mX-*.sh` sont la source de vérité**. Les targets
  Makefile sont des thin wrappers. Quand tu veux savoir « est-ce que ce jalon
  est livré ? », tu lis le script — pas la doc, pas le Makefile.
- **Le mode statique passe toujours** — le mode `--live` exige la stack up et
  les bons ports (utilise `BAAS_VERIFY_SAFE_PORTS=1` pour éviter les conflits).
- **Les artefacts de scan** atterrissent dans
  [`apps/baas/mini-baas-infra/artifacts/security/`](../../apps/baas/mini-baas-infra/artifacts/security/).
