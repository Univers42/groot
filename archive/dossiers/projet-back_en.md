> **Automatic translation.** Machine-translated from `wiki/dossiers/projet-back.md` (French).
> The original describes the repository **as of 12 April 2026**, before the flatten: paths and
> structure refer to the old `mini-baas-infra/` layout, which no longer exists. Use it for the
> rationale, scope and skills coverage; for the current architecture and paths see
> `apps/grobase/CLAUDE.md`.

# 📁 mini-baas-infra — Back-End Architecture Documentation

> Self-hosted BaaS platform, Docker Compose oriented, designed as a **generic backend factory** capable of providing authentication, relational data, document data, multi-tenant querying, real time, object storage, transactional email and unified security policies without developing specific business APIs for each new project.

---

## 📋 Table of Contents

1. [Team information](#team-information)
1. [List of Skills Covered](#1-list-of-skills-covered)
1. [Expression of Needs](#2-expression-of-needs)
   - 2.1 [Project Objectives](#21-project-objectives)
   - 2.2 [Project Limits](#22-project-limitations)
   - 2.3 [Expected Deliverables](#23-expected-deliverables)
1. [Technical Environment](#3-technical-environment)
   - 3.1 [Front-End Technologies](#31-front-end-technologies)
   - 3.2 [Back-End Technologies](#32-back-end-technologies)
   - 3.3 [Tools & Development Environment](#33-tools-development-environment)
1. [Front-End Projects](#4-front-end-achievements)
   - 4.1 [User Interface Mockups](#41-user-interface-mockups)
   - 4.2 [Mockup flow](#42-mockup-flow)
   - 4.3 [Static Interfaces](#43-static-interfaces)
   - 4.4 [Dynamic Part of Interfaces](#44-dynamic-part-of-interfaces)
   - 4.5 [Web Adaptation & Mobile Web (Responsive)](#45-web-mobile-web-adaptation-responsive)
1. [Back-End Achievements](#5-back-end-achievements)
   - 5.1 [Architecture & Structure](#51-architecture-structure)
   - 5.2 [Database](#52-database)
   - 5.3 [API / Routes](#53-api-routes)
1. [Security](#6-security)
   - 6.1 [Front-End Side Security Measures](#61-front-end-security-measures)
   - 6.2 [Vulnerability Monitoring](#62-monitoring-of-vulnerabilities)
1. [Trial Game](#7-trial-game)
1. [Installation & Use](#8-installation-use)
   - 8.1 [Prerequisites](#81-prerequisites)
   - 8.2 [Installation](#82-installation)
   - 8.3 [Project Launch](#83-project-launch)

- 8.4 [Service-by-service startup sequence](#84-service-by-service-startup-sequence)
- 8.5 [Full cycle of main queries](#85-complete-cycle-of-main-queries)

1. [Risks, Limitations & Future Improvements](#9-risks-limitations-future-improvements)
1. [Glossary](#10-glossary)
1. [Project Structure](#11-project-structure)
1. [Source File Mapping](#12-source-file-mapping)
1. [Appendices](#13-appendices)

---

# Team information

## Observed composition of the project

In the current state of the repository, the project seems to be carried out mainly by **dlesieur**. This documentation is written so that it can be used in an individual **or** collective educational setting.

### Proposed distribution of roles

| Member | Main role | Responsibilities observed/inferred |
| -------- | -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| dlesieur | Product Owner / Tech Lead / DevOps / Back-End Lead | Architecture design, Docker integration, service orchestration, security, writing NestJS services, operating tools, technical documentation |

> If the project is presented as a group, this table can be enriched with the real names of the team. The documentation structure below remains valid.

## Project organization

### Working methodology

The repository shows an **incremental and modular** approach:

- construction by independent services;
- gradual increase in complexity;
- documentation parallel to the implementation;
- regular validation by phased test scripts;
- clear separation between infrastructure, application services, scripts, documentation and configuration.

This strategy is consistent with an approach such as:

- **iterative** for adding features;
- **DevOps** for automating the build, run and checks;
- **contract-first** for several components exposed via routes and DTOs;
- **security-first** for authentication, isolation and encryption.

### Management and communication tools

Even if not all external tools are visible in the repository, the structure reveals a practice compatible with:

- Git / GitHub for versioning;
- Issues / milestones / branches for traceability;
- Markdown documentation as a basis for technical communication;
- shell scripts and Makefile as execution standard for the team;
- Docker Compose as a shared deployment contract.

## Global technical stack

| Domain | Choice | Rationale |
| -------------------- | -------------------------------------- | -------------------------------------------------------------------------------- |
| Local orchestration | Docker Compose | Reproducibility, isolation, ease of start-up |
| Gateway | Kong | Centralization of plugins, auth, rate-limit, CORS, routing |
| Auth | GoTrue | Out-of-the-box account management, JWT, MFA, refresh token rotation |
| SQL REST | PostgREST | Automatically exposing a relational API without writing business controllers |
| Relational DB | PostgreSQL 16 | RLS, robustness, mature SQL, extensibility |
| Document DB | MongoDB 7 | Flexible model, change streams, adaptation to non-strictly relational data |
| Custom microservices | NestJS 10 + TypeScript 5 | Modularity, DI, DTO, maintainability |
| Real time | realtime-agnostic | Real-time broadcast of PostgreSQL and MongoDB mutations |
| Object storage | MinIO + AWS SDK S3 | S3 compatibility and self-hosting simplicity |
| Email | Nodemailer + SMTP | Simple, interoperable standard, decoupled from the supplier |
| Observability | Prometheus + Grafana + Loki + Promtail | Centralized measurements, dashboards and logs |
| Security of secrets | Vault + AES-256-GCM encryption | Reducing Secret Exposure and Encrypting Sensitive Credentials |

## Database: overall logic

The project is not based on **a single** database, but on several layers:

1. **PostgreSQL system**: stores users, roles, policies, registers, SQL business tables.
2. **MongoDB system**: stores collection-oriented documents with isolation by `owner_id`.
3. **Registered external databases**: PostgreSQL or third-party MongoDB, dynamically connected via the `adapter-registry`.
4. **Internal registries**: `tenant_databases`, `schema_registry`, `roles`, `user_roles`, `resource_policies`.

## List of implemented features

### Core features

| Feature | Description |
| --------------------- | ------------------------------------------------------------------ |
| Authentication | Registration, login, JWT, MFA, refresh token rotation |
| Centralized gateway | Unique routing, security plugins, exchange standardization |
| Generic SQL API | Automatic REST on PostgreSQL via PostgREST |
| Generic Mongo API | Proprietary CRUD on MongoDB collections |
| Universal query | `query-router` to external PostgreSQL or MongoDB |
| Basic register | Dynamic addition of remote databases, encrypted credentials |
| Schema generation | Creating tables/collections from a unified specification |
| Access control | RBAC + ABAC via roles, policies, `has_permission()` function |
| File storage | Generation of MinIO compatible S3 presigned URLs |
| Transactional Email | SMTP sending via dedicated service |
| Real time | Dissemination of data changes |
| Observability | Logs, metrics, dashboards |
| Validation and scripts | Shell checks, compose, secrets, smoke tests |

## Educational modules — proposed categorization

> This subsection can be used in an exercise context. The weighting below is a **proposed educational reading** of the complexity of the system.

### Major modules (2 pts)

| Module | Type | Why major |
| ---------------------------- | ------ | --------------------------------------------------------- |
| Kong Gateway | Major | Single point of entry, cross-functional security, routing |
| GoTrue Auth + JWT | Major | Identity, token issuance, MFA, user security |
| PostgreSQL + PostgREST + RLS | Major | Self-exposed relational data plane |
| MongoDB + mongo-api | Major | Self-exposed document data plane |
| adapter-registry | Major | Foundation of the generic multi-database backend |
| query-router | Major | Universal query without dedicated business endpoint |
| service-schema | Major | Generation of schemas and industrialization of structures |
| permission-engine | Major | Access governance and ABAC |

### Minor modules (1 pt)

| Module | Type | Why minor |
| ------------------------------------ | ------ | --------------------------------------------------- |
| storage-router | Minor | Important but peripheral to the core data/auth |
| email-service | Minor | Simple but useful cross-functional service |
| Vault | Minor | Environmental security and secrets management |
| Observability | Minor | Essential in production, indirect functionally |
| Trino / Studio / pg-meta / Supavisor | Minor | Admin, mining or optimization services |
| Automation Scripts | Minor | Quality and Operation Support |

---

## 1. List of Skills Covered

This project implements the following skills from the repository, reinterpreting them in a context strongly oriented back-end, architecture and integration.

**Activity Type 1 – Develop the front-end part of a secure web or mobile web application**

| # | Skill | Implementation in the project |
| --- | --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1 | Mockup web or mobile web user interfaces | The repository does not contain a final product front, but the architecture is designed to support any front via unified API; usage paths can be documented in the form of client-side screen flows |
| C2 | Create static web or mobile web user interfaces | The repository contains a `playground` and integration conventions; the final interface part is deliberately decoupled from the back-end |
| C3 | Develop the dynamic part of web or mobile web user interfaces | The system is designed to power dynamic interfaces using HTTP, JWT, WebSocket and generic APIs |

**Activity Type 2 – Develop the back-end part of a secure web or mobile web application**

| # | Skill | Implementation in the project |
| --- | --------------------------------------------- | ------------------------------------------------------------------------------------ |
| B1 | Design an application architecture | Specialized microservices, single gateway, data plane separation |
| B2 | Set up a database | PostgreSQL, MongoDB, roles, policies, migrations, dynamic schemas |
| B3 | Develop Data Access Components | SQL/Mongo engines, adapter registry, query-router |
| B4 | Expose secure network services | Kong, JWT, key-auth, rate limiting, WAF |
| B5 | Industrialize and deploy | Docker Compose, bake, Makefile, validation scripts |
| B6 | Guarantee security | RLS, owner isolation, AES-256-GCM encryption, Vault, DTOs, guards |

---

## 2. Expression of Needs

### 2.1 Project Objectives

The project responds to a very clear need: **have a reusable backend for any product without having to recode a specific server for each new use case**.

### Problem to solve

In many projects, a significant portion of time is spent rebuilding the same bricks:

- authentication;
- user management;
- relational storage;
- document storage;
- Basic CRUD;
- access control;
- email;
- file upload;
- logs and observability;
- secure data exposure.

The objective here is to transform these repetitive bricks into **generic engines**.

### Main objective

Build a self-hosted BaaS platform that allows a front-end, business product, or other service to consume full back-end capabilities **without writing a core business API**.

### Secondary objectives

- unify authentication behind a single entry point;
- support PostgreSQL **and** MongoDB;
- support external databases recorded dynamically;
- industrialize the creation of schemas;
- apply native security;
- provide a base that can be used locally, for demonstration or pre-production;
- enable observability and operations;
- make the system extensible to other engines and services.

### Target audience

| Target | Usage |
| --------------------- | ------------------------------------------------------------------------------ |
| Front-end developer | Consume auth, data, realtime and files without building your own backend |
| Product Team | Quickly start an MVP with already secure primitives |
| Integrator / DevOps | Deploy an internal shared back-end services platform |
| Teaching team | Demonstrate a modern, modular and secure architecture |

### 2.2 Project Limitations

The scope is deliberately focused on the generic back-end. The project **does not** directly cover:

- a finalized business front-end application;
- business logic specific to a specific functional area;
- complete visual administration of all custom engines;
- a production Kubernetes cluster;
- multi-region management;
- a complete CI/CD workflow in this very repository;
- compatibility with all existing SQL/NoSQL engines.

### Current technical limits to be aware of

- the generic custom main engine mainly targets PostgreSQL and MongoDB;
- universal requests remain voluntarily regulated to maintain a good level of security;
- certain advanced extensions (federation, admin UI, object storage) are under optional profiles;
- client fronts must respect auth, API key and JWT contracts.

### 2.3 Expected Deliverables

- [x] Functional Docker Compose infrastructure
- [x] Centralized API gateway
- [x] Authentication out of the box
- [x] Generic SQL Data Plane
- [x] Generic MongoDB data plane
- [x] Multi-tenant query to external databases
- [x] SQL/Mongo schema generator
- [x] RBAC/ABAC permissions engine
- [x] Detailed technical documentation
- [x] Validation and test scripts
- [x] Technical demo support

---

## 3. Technical Environment

### 3.1 Front-End Technologies

This repository is **back-end first**. It does not include a complete final application interface, but it is explicitly designed to be consumed by any front-end.

| Technology | Release | Role |
| ------------------------------ | --------------------- | ---------------------------------------------------------------- |
| HTML5 | - | Consumption possible by any web client |
| CSS3 | - | Outside the main repository, used by any front connected to BaaS |
| JavaScript / TypeScript | Variable depending on customer | API integration, JWT management, real-time calls |
| React / Vue / Angular / mobile | Not taxed | The architecture is intentionally client-agnostic |

### Why the front-end is not coupled to the repository

The fundamental architectural choice of the project consists of **not** locking the solution into a single front. The platform must be able to serve:

- a Web SPA;
- a mobile application;
- a back office;
- a chatbot;
- another microservice.

In other words, the front is not absent due to lack, but because the project aims for a role of **shared backend infrastructure**.

### 3.2 Back-End Technologies

| Technology | Release | Role |
| --------------------------- | ------------------------------ | ---------------------------------------------- |
| TypeScript | 5.7.3 | NestJS microservices core language |
| Node.js | 20 (Dockerfile) | Custom Services Runtime |
| NestJS | 10.x | Modular framework for back-end services |
| PostgreSQL | 16-alpine | Main relational database |
| MongoDB | 7 | Main document database |
| Kong | 3.8 | API Gateway and access policy |
| GoTrue | v2.188.1 | Authentication, JWT, MFA |
| PostgREST | v12.2.3 | Automatic REST API on PostgreSQL |
| Redis | 7-alpine | Cache / infra support |
| MinIO | RELEASE.2025... | S3 compatible object storage |
| Nodemailer | 6.9.x | SMTP Email Sending |
| Prometheus / Grafana / Loki | versions defined in Compose | Observability |

### Significant libraries

| Library | Role |
| ----------------------------- | ---------------------------------------- |
| `class-validator` | Validation of DTOs |
| `class-transformer` | Transforming incoming requests |
| `nestjs-pino` | Structured logs |
| `@nestjs/axios` | Inter-service HTTP calls |
| `pg` | Custom PostgreSQL connection |
| `mongodb` | Custom MongoDB client |
| `@aws-sdk/client-s3` | Interaction with MinIO/S3 |
| `@willsoto/nestjs-prometheus` | Prometheus Metrics for Services |
| `uuid` | Identifier generation and correlation |

### 3.3 Tools & Development Environment

| Tool | Usage |
| ----------------------- | -------------------------------------------------------- |
| VS Code | Code editing and navigation |
| Git/GitHub | Versioning, logging, collaboration |
| Docker / Docker Compose | Local and orchestrated execution |
| Make | Simplified operating controls |
| Bash | Validation scripts, secret generation, migrations |
| Mermaid | Architecture and flow diagrams |
| Swagger / OpenAPI | NestJS Services API Documentation |

### Build architecture

The repository contains a unified `src/Dockerfile` allowing you to build the 7 NestJS applications via an `APP` argument.

Significant extract:
```dockerfile
ARG APP=adapter-registry

FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY --link package.json package-lock.json ./
RUN npm ci

FROM deps AS build
ARG APP
COPY --link tsconfig.json tsconfig.build.json nest-cli.json ./
COPY --link libs/ ./libs/
COPY --link apps/ ./apps/
RUN npx nest build ${APP}
```
This choice avoids maintaining a Dockerfile per microservice, reduces duplication and reinforces the consistency of the monorepo.

---

## 4. Front-End Achievements

> This section follows the plan requested by the exercise. As the repository is focused on the back-end, the front-end part is described as an **expected integration model** rather than as a final visual product delivered to this repository.

### 4.1 User Interface Mockups

The system is designed to supply several families of interfaces:

1. **business client application**;
2. **back office administration**;
3. **development console / playground**;
4. **mobile application**;
5. **consumer microservice**.

### Typical functional model — client application
```mermaid
flowchart TD
    A[Accueil] --> B[Connexion / Inscription]
    B --> C[Dashboard]
    C --> D[Liste des ressources SQL]
    C --> E[Liste des documents MongoDB]
    C --> F[Fichiers / Upload]
    C --> G[Notifications temps réel]
    C --> H[Profil / rôles / sécurité]
```
### Typical functional model — administration console
```mermaid
flowchart TD
    A[Admin Home] --> B[Gestion des bases enregistrées]
    A --> C[Création de schémas]
    A --> D[Gestion des policies]
    A --> E[Logs & métriques]
    A --> F[Stockage objet]
```
### Recommended ergonomic choices

- clear separation between auth, data, storage, administration;
- display of the current user context (id, role, tenant);
- explicit visibility of permissions;
- standardized error return;
- logging of critical requests on the console side.

### Recommended locations for screenshots

In a version submitted to the jury, it is strongly recommended to insert captures or mockups in the following locations:

1. **login/registration screen**;
2. **main dashboard** with links to SQL, MongoDB, schemas, permissions;
3. **external database registration screen**;
4. **schema creation screen**;
5. **universal query screen**;
6. **observability screen** with metrics or logs;
7. **policy management screen**.

#### Figure Placeholder — authentication

> **Figure 1 — Authentication screen**
> _Insert here a capture showing the email, password, possibly MFA fields, as well as the recovery/registration process._

#### Figure placeholder — dashboard

> **Figure 2 — Platform dashboard**
> _Insert here a screenshot of the main screen presenting the auth, SQL, Mongo, schemas, storage, permissions and monitoring modules._

#### Figure Placeholder — Databases Register

> **Figure 3 — External database registration interface**
> _Insert here a screenshot of the form allowing you to choose the engine, the logical name and the connection string._

#### Figure placeholder — observability

> **Figure 4 — Observability Dashboard**
> _Insert here a Grafana or Prometheus capture illustrating the state of the system and supervision._

### 4.2 Mockup flow

The back-end is built to support the following user cycle:
```mermaid
sequenceDiagram
    participant U as Utilisateur
    participant FE as Front-end
    participant K as Kong
    participant G as GoTrue
    participant S as Services

    U->>FE: Ouvre l'application
    FE->>K: POST /auth/v1/signup ou /token
    K->>G: Route auth
    G-->>FE: JWT + refresh token
    FE->>K: Appels API avec apikey + Bearer JWT
    K->>S: Routage + headers injectés
    S-->>FE: Données sécurisées
```
### 4.3 Static Interfaces

The recommended static interface to consume the project can be structured around simple blocks:
```html
<header class="topbar">
  <h1>Mini BaaS Console</h1>
  <div class="session">
    <span id="user-email"></span>
    <button id="logout">Se déconnecter</button>
  </div>
</header>

<main class="layout">
  <aside class="sidebar">
    <button data-view="sql">SQL</button>
    <button data-view="mongo">MongoDB</button>
    <button data-view="schemas">Schemas</button>
    <button data-view="policies">Policies</button>
    <button data-view="storage">Storage</button>
  </aside>

  <section class="content" id="app-view"></section>
</main>
```
Possible CSS extract:
```css
.layout {
  display: grid;
  grid-template-columns: 280px 1fr;
  min-height: 100vh;
}

.sidebar {
  border-right: 1px solid #e5e7eb;
  padding: 1rem;
}

.content {
  padding: 1.5rem;
  background: #fafafa;
}
```
### 4.4 Dynamic Part of Interfaces

The typical front-end mainly exploits:

- `fetch` / `axios` calls;
- temporary storage of JWT;
- the addition of the `apikey` and `Authorization` headers;
- WebSockets for real time;
- display of paginated responses.

Example of a dynamic call to the `query-router`:
```javascript
async function queryExternalDatabase(dbId, table, token, apikey, payload) {
  const res = await fetch(`/query/v1/query/${dbId}/tables/${table}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
      apikey,
    },
    body: JSON.stringify(payload),
  });

  if (!res.ok) {
    throw new Error(`HTTP ${res.status}`);
  }

  return res.json();
}
```
### 4.5 Web & Mobile Web Adaptation (Responsive)

The system is particularly compatible with a responsive approach because the business logic is carried on the API side and not on the rendering side. The front therefore only has to manage:

- the session;
- forms;
- display of data;
- loading status;
- errors.

Example of responsive rules:
```css
@media (max-width: 768px) {
  .layout {
    grid-template-columns: 1fr;
  }

  .sidebar {
    border-right: 0;
    border-bottom: 1px solid #e5e7eb;
  }
}
```
---

## 5. Back-End Achievements

### 5.1 Architecture & Structure

The project follows a **microservices integrated by gateway** architecture, with a strong **backend factory** orientation.

### Main idea

The system is not a single application back-end, but a **foundation** capable of powering several different projects using generic primitives.

### Central architectural principle

Instead of creating for each project:

- an auth service;
- a users service;
- a CRUD SQL;
- a NoSQL CRUD;
- an upload engine;
- a system of policies;
- an email service;

...the repository builds an already ready **shared platform**.

### Overall architecture diagram
```mermaid
graph TB
    subgraph Client[Clients]
        WEB[Web App]
        MOB[Mobile App]
        BO[Back Office]
        MS[Other Services]
    end

    subgraph Entry[Entrée unique]
        WAF[WAF / ModSecurity]
        KONG[Kong Gateway]
    end

    subgraph Identity[Identité]
        GOTRUE[GoTrue]
    end

    subgraph GenericData[Plans de données génériques]
        POSTGREST[PostgREST]
        MONGOAPI[mongo-api]
        QUERY[query-router]
        SCHEMA[schema-service]
        REGISTRY[adapter-registry]
        PERM[permission-engine]
        STORAGE[storage-router]
        EMAIL[email-service]
        REALTIME[realtime-agnostic]
    end

    subgraph Persistence[Persistance]
        PG[(PostgreSQL)]
        MG[(MongoDB)]
        S3[(MinIO / S3)]
        RD[(Redis)]
        EXT1[(External PostgreSQL)]
        EXT2[(External MongoDB)]
    end

    WEB --> WAF --> KONG
    MOB --> WAF
    BO --> WAF
    MS --> KONG

    KONG --> GOTRUE
    KONG --> POSTGREST
    KONG --> MONGOAPI
    KONG --> QUERY
    KONG --> SCHEMA
    KONG --> REGISTRY
    KONG --> PERM
    KONG --> STORAGE
    KONG --> EMAIL
    KONG --> REALTIME

    GOTRUE --> PG
    POSTGREST --> PG
    PERM --> PG
    REGISTRY --> PG
    SCHEMA --> PG
    MONGOAPI --> MG
    STORAGE --> S3
    REALTIME --> PG
    REALTIME --> MG
    QUERY --> EXT1
    QUERY --> EXT2
    SCHEMA --> EXT1
    SCHEMA --> EXT2
    RD --- KONG
```
### Role of the major layers

| Layer | Role |
| ------------------- | --------------------------------------------------- |
| Ingress | WAF+Kong |
| Identity | GoTrue |
| Data plane SQL | PostgREST + PostgreSQL |
| Data plane document | mongo-api + MongoDB |
| External data plane | adapter-registry + query-router + schema-service |
| Policy plan | permission-engine |
| Side services | storage-router, email-service, realtime |
| Plane Ops | Prometheus, Grafana, Loki, Vault, Makefile, scripts |

### Monorepo NestJS

The monorepo `src/` contains:

- **7 applications**;
- **3 shared libraries**.

#### Apps

| Application | Role |
| ------------------- | -------------------------------------------------------------- |
| `adaptor-registry` | store encrypted external database connections |
| `query-router` | execute generic operations on saved databases |
| `schema-service` | create/delete tables or collections on saved databases |
| `permission-engine` | manage ABAC/RBAC roles and policies |
| `mongo-api` | Local MongoDB Generic CRUD |
| `storage-router` | generate presigned URLs |
| `email-service` | send SMTP emails |

#### Libraries

| Library | Role |
| --------------- | ---------------------------------------------- |
| `libs/common` | guards, decorators, filters, pipes, interfaces |
| `libs/database` | shared PostgreSQL and MongoDB services |
| `libs/health` | standardized live/ready endpoints |

### Typical query flow
```mermaid
sequenceDiagram
    participant C as Client
    participant W as WAF
    participant K as Kong
    participant A as Auth / JWT plugin
    participant S as Service cible
    participant D as DB / Engine

    C->>W: Requête HTTP
    W->>K: Requête filtrée
    K->>A: key-auth + jwt + plugins
    A->>K: validation OK
    K->>S: headers injectés (X-User-Id, X-User-Role...)
    S->>D: opération métier ou générique
    D-->>S: résultat
    S-->>K: réponse JSON standardisée
    K-->>C: réponse enrichie headers sécurité
```
### Why this architecture is generic

The generic character comes from several structuring choices:

1. **the routes do not encode a specific business domain**;
2. **schemas can be created dynamically**;
3. **external databases can be hot-saved**;
4. **access controls are data driven**;
5. **the front only consumes standard primitives**;
6. **services are substitutable and decoupled**.

In other words, the repository acts as a **back-end programmable by configuration, schema and policies**, and not as ad hoc application code.

### Academic reading of architecture

In a more academic reading, this platform can be understood as the combination of four complementary plans:

1. **identity plan**: authenticates users and produces identity proofs;
2. **control plan**: decides who can do what;
3. **data plane**: actually executes database operations;
4. **operations plan**: observes, deploys, validates and maintains the platform.

This separation is important because it avoids confusing:

- proof of identity,
- the authorization decision,
- data manipulation,
- and operational governance.

From a software engineering perspective, this approach improves:

- **maintainability**, because each service has a clear responsibility;
- **organizational scalability**, because several teams can intervene per domain;
- **reusability**, because the primitives remain independent of a profession;
- **testability**, because each layer can be validated separately.

### Detail service by service

#### 1. Kong Gateway

Kong is the **single entry point**.

Functions provided:

- routing;
- `key-auth` plugin;
- `jwt` plugin;
- `cors`;
- `correlation-id`;
- `response-transformer` for security headers;
- `rate-limiting`;
- `request-size-limiting`;
- `ip-restriction` on certain administration routes;
- `pre-function` plugin to propagate JWT claims to services in trusted headers.

Important extract from the behavior: the JWT is verified by Kong, then its claims are projected into:

- `X-User-Id`
- `X-User-Email`
- `X-User-Role`
- `X-Request-ID`

NestJS services therefore do not need to revalidate the JWT themselves for the standard route via gateway.

#### 2. GoTrue

GoTrue provides:

-signup;
- login;
- JWT;
- MFA/TOTP;
- refresh token rotation;
- Configurable external OAuth;
- email auth.

It constitutes the **source of identity** of the system.

#### 3. PostgreSQL + PostgREST

This pair automatically exposes a relational API. The choice is very strong: rather than coding specific CRUD controllers, we let PostgREST generate the API from SQL tables and rights.

Security is guaranteed by RLS policies.

#### 4. MongoDB + mongo-api

MongoDB does not have a native equivalent of PostgREST. The project therefore provides a custom `mongo-api` service which implements a generic owner-scoped CRUD.

Features :

- `owner_id` injected automatically;
- filters cleaned;
- `_id` validated;
- paging;
- sorting;
- Prometheus metrics;
- separate admin operations.

#### 5. adapter-registry

Central service for **dynamic connection to external databases**.

Functions:

- save a PostgreSQL or MongoDB database;
- encrypt its connection string;
- apply multi-tenant isolation via RLS on `tenant_databases`;
- allow authorized internal services to recover the decrypted secret.

Without it, there is no multi-project factory backend.

#### 6. query-router

The `query-router` is the universal engine for accessing registered databases.

He :

- requests connection to the registry;
- detects the engine;
- delegates to the PostgreSQL or MongoDB engine;
- imposes user isolation;
- enforces query limits.

It therefore allows you to query **any registered database** without writing a custom endpoint.

#### 7. schema-service

The `schema-service` industrializes the creation of structures.

It takes a unified specification (`name`, `engine`, `database_id`, `columns`, etc.), then:

- creates a PostgreSQL table with standardized columns and RLS;
- or create a MongoDB collection with JSON Schema validator;
- saves the result in `schema_registry`.

This service is what brings the project closest to a **backend factory** in the strong sense: we no longer create structures by hand in each project.

#### 8. permission-engine

The permissions engine manages:

- the roles;
- user roles;
- resource/action policies;
- the SQL function `has_permission()`.

It completes the RLS:

- the RLS protects the lines;
- the permission-engine governs more general application access.

#### 9. storage-router

This service generates pre-signed S3 URLs. It avoids exposing storage credentials to the client.

It also applies simple isolation by prefixing the path with the user identifier.

#### 10. email-service

Service dedicated to sending SMTP emails: decoupling of transport, maintaining clear responsibility and sharing between projects.

#### 11. realtime

Real-time change distribution service. It complements CRUD operations by allowing a front to react to data mutations without permanent polling.

### Subsections dedicated to NestJS applications

The preceding paragraphs give a summary view. For a defense reading, it is useful to go further application by application.

#### `adapter-registry` — secure adapter registry

**Main responsibility:** make the link between a user/tenant and a dynamically recorded external database.

**Functional capabilities:**

- register an engine (`postgresql`, `mongodb`, etc.);
- store the logical name of a database;
- encrypt the connection string;
- list the databases visible to the current tenant;
- provide the decrypted secret to authorized internal services;
- delete a registry entry.

**Notable technical choices:**

- AES-256-GCM encryption;
- `tenant_databases` table protected by RLS;
- `ServiceTokenGuard` for internal access to the connection endpoint;
- Swagger exhibition;
- use of shared `PostgresService`.

**Interest in architecture:** it is the brick that makes the platform multi-project and multi-database. Without it, the system would remain limited to internal databases.

#### `query-router` — universal query engine

**Primary Responsibility:** Provide a single point of access to execute generic operations on a registered database.

**Functional capabilities:**

- resolution of the actual connection;
- SQL / Mongo engine dispatch;
- standardized CRUD operations;
- limitation of results;
- support for filtering and sorting;
- user context propagation for isolation.

**Notable technical choices:**

- PostgreSQL engine with table/column name validation;
- MongoDB engine with filter cleaning;
- automatic injection of `owner_id` on insertion;
- propagation of `app.current_user_id` for RLS external tables.

**Interest in the architecture:** it removes the need to write a data access service for each external database and each project.

#### `schema-service` — industrialization of structures

**Primary Responsibility:** Transform a unified schema specification into an actual physical structure on a PostgreSQL or MongoDB engine.

**Functional capabilities:**

- PostgreSQL table creation;
- RLS activation on an external database;
- MongoDB collection creation;
- installation of a JSON Schema validator;
- deletion of structures;
- registration of the produced schema in `schema_registry`.

**Notable technical choices:**

- systematic addition of technical columns;
- safeguards on supported SQL types;
- creation of a `current_user_id()` function for external PostgreSQL databases;
- persistence of a central register of created schemas.

**Interest in the architecture:** it transforms the repository into a data structure factory, and not just an HTTP gateway.

#### `permission-engine` — governance and ABAC

**Primary responsibility:** express rights in the form of roles and policies in a centralized manner.

**Functional capabilities:**

- role assignment;
- revocation;
- consultation of a user's roles;
- creation/deletion of policies;
- evaluation of access via `has_permission()`.

**Notable technical choices:**

- SQL storage of roles and policies;
- hierarchy by priority;
- deny-first logic with equal priority;
- articulation with `RolesGuard` on the API side.

**Interest in the architecture:** it prevents authorization rules from being dispersed in each microservice or client application.

#### `mongo-api` — generic document data plane

**Primary Responsibility:** Expose clean CRUD on local MongoDB without specific business code.

**Functional capabilities:**

- creation of documents;
- paginated and filtered reading;
- reading by identifier;
- partial update;
- deletion;
- schema/index administration endpoints.

**Notable technical choices:**

- injection of `owner_id`;
- deletion of prohibited fields;
- validation of ObjectIds;
- Prometheus instrumentation;
- separation between `collections` and `admin`.

**Interest in the architecture:** it provides to MongoDB what PostgREST provides to PostgreSQL: a stable generic API layer.

#### `storage-router` — object storage access facade

**Main responsibility:** secure access to storage by generating temporary URLs.

**Functional capabilities:**

- GET signature;
- PUT signature;
- controlled expiration time;
- automatic prefixing of the path with the user.

**Interest in the architecture:** it removes from the front the responsibility of handling S3 access secrets.

#### `email-service` — transversal sending service

**Main responsibility:** centralize SMTP sending and decouple business applications from email transport.

**Functional capabilities:**

- HTML or text sending;
- external SMTP configuration;
- connectivity check;
- structured logging.

**Interest in the architecture:** pooling email avoids having to recode the same logic in each consumer project.

### Subsections dedicated to shared libraries

#### `libs/common`

This library pools the security and transport vocabulary: `AuthGuard`, `RolesGuard`, `ServiceTokenGuard`, `CurrentUser` decorator, exception filter, validation pipe, correlation interceptor.

**Architectural contribution:** it avoids divergence of behavior between services.

#### `libs/database`

This library provides the `PostgresService` and `MongoService` services.

**Architectural contribution:** centralization of pools, connection health, and access patterns.

#### `libs/health`

This library standardizes `live` and `ready` endpoints.

**Architectural contribution:** facilitates Compose orchestration, healthchecks and observability.

### Subsections dedicated to Docker infrastructure services

Beyond the NestJS applications, the architecture is based on several infrastructure containers which also deserve a detailed reading.

#### `waf`

This container acts as the initial HTTP shield. It complements Kong with a defense logic more oriented towards filtering suspicious patterns.

#### `kong`

Kong is the nerve center of HTTP traffic. Its declarative file defines:

- roads;
- upstream services;
- global plugins;
- rules specific to certain endpoints.

#### `postgres`

Main relational database of the system. It carries both demonstration data and critical architecture metadata.

#### `db-bootstrap`

One-shot preparation job:

- SQL roles;
- auth schema;
- demonstration tables;
- RLS policies;
- register tables;
- basic permissions.

Its existence reinforces the reproducible nature of the platform.

#### `mongo` + `mongo-init`

MongoDB is started with a replica set to support change streams. `mongo-init` finalizes the initialization.

#### `gotrue`

System identity provider. It replaces the need for tailor-made development for the entire accounts, login and MFA section.

#### `postgrest`

Exposes relational data directly from PostgreSQL. This is a considerable accelerator for building a backend without re-developing basic operations.

#### `realtime`

Broadcasts data changes. It is the building block that brings the platform closer to a modern event-oriented experience.

#### `redis`

Support service for the stack, useful for certain cache patterns or real-time components depending on usage scenarios.

#### `minio`

Provides self-hosted S3-compatible object storage, activateable in `extras` profile.

#### `vault` + `vault-init`

Participate in the overall secrets management strategy. Even though the project also uses a `.env` for local, the architecture shows an orientation towards more mature management of secrets.

#### `prometheus`, `grafana`, `loki`, `promtail`

They constitute the observability plan:

- metrics;
- dashboards;
- centralization of logs.

#### `studio`, `pg-meta`, `supavisor`, `trino`

Additional administration, pooling and mining services. They are not mandatory at the heart of the backend, but strengthen the platform ecosystem.

### Comparison with a classic custom backend

To better understand the originality of the project, it is useful to compare it to a more traditional architecture in which a team manually builds its business API.

| Criterion | Specific classic backend | mini-baas-infra |
| -------------------------- | ---------------------------------------- | ------------------------------------ |
| Authentication | Often developed or integrated by hand | Shared via GoTrue |
| CRUDSQL | Controllers and specific services | Automatic via PostgREST |
| CRUD Mongo | Often ad hoc by collection | Generic via `mongo-api` |
| Management of external databases | Rare, expensive, specific | Native via `adapter-registry` |
| Schema creation | Dedicated scripts or migrations per project | Generic via `schema-service` |
| Permissions | Often scattered throughout the code | Centralized via `permission-engine` |
| Storage | Integration by project | Shared via `storage-router` |
| Email | Specific implementation | Shared via `email-service` |
| Reusability | Low to medium | High |
| Time-to-market | Longer | Reduced |

This comparison shows that the project is not just a technical stack: it explicitly reduces structural redundancy between projects.

### Shared Authentication Guard Example
```typescript
canActivate(context: ExecutionContext): boolean {
  const req = context.switchToHttp().getRequest<Request>();
  const userId = req.headers['x-user-id'] as string | undefined;

  if (!userId) {
    throw new UnauthorizedException('Missing authenticated user headers');
  }

  req.user = {
    id: userId,
    email: (req.headers['x-user-email'] as string | undefined) ?? '',
    role: (req.headers['x-user-role'] as string | undefined) ?? 'authenticated',
  };

  return true;
}
```
This code clearly shows the philosophy of the project: the service trusts the gateway, which greatly simplifies the microservices.

### Example of recovering a saved database
```typescript
private async fetchConnection(dbId: string, userId: string): Promise<AdapterResponse> {
  const url = `${this.registryUrl}/databases/${dbId}/connect`;
  const { data } = await firstValueFrom(
    this.http.get<AdapterResponse>(url, {
      headers: {
        'X-Service-Token': this.serviceToken,
        'X-Tenant-Id': userId,
      },
    }),
  );
  return data;
}
```
The `query-router` does not embed any hard secrets for external databases: it always goes through the registry.

### Example of encryption logic

The registry encrypts connection strings with AES-256-GCM and `scrypt` derivation.

Why this choice?

- confidentiality at rest;
- authenticity of the data via GCM tag;
- cryptographic robustness;
- natural adaptation to binary storage in the database.

---

### 5.2 Database

The database strategy is **polyglot**.
```mermaid
flowchart LR
    subgraph Internal
        PGSYS[(PostgreSQL système)]
        MGSYS[(MongoDB système)]
    end

    subgraph External
        PGTEN[(PostgreSQL externes)]
        MGTEN[(MongoDB externes)]
    end

    REG[adapter-registry] --> PGSYS
    PERM[permission-engine] --> PGSYS
    POST[PostgREST] --> PGSYS
    MAPI[mongo-api] --> MGSYS
    QUERY[query-router] --> PGTEN
    QUERY --> MGTEN
    SCHEMA[schema-service] --> PGTEN
    SCHEMA --> MGTEN
```
### Main relational model

The PostgreSQL system contains several families of tables.

#### Business tables / demonstration

- `users`
- `user_profiles`
- `posts`
- `projects`
- `mock_orders`

#### Infrastructure tables

- `tenant_databases`
- `schema_registry`
- `roles`
- `user_roles`
- `resource_policies`
- `schema_migrations`

### Simplified logic diagram
```mermaid
erDiagram
    USERS ||--o{ USER_PROFILES : owns
    USERS ||--o{ POSTS : writes
    USERS ||--o{ USER_ROLES : receives
    ROLES ||--o{ USER_ROLES : grants
    ROLES ||--o{ RESOURCE_POLICIES : defines
    TENANT_DATABASES ||--o{ SCHEMA_REGISTRY : contains

    USERS {
        uuid id PK
        text email
        text name
        timestamptz created_at
    }

    USER_PROFILES {
        uuid id PK
        uuid user_id FK
        text bio
        text avatar_url
    }

    POSTS {
        uuid id PK
        uuid user_id FK
        text title
        text content
        boolean is_public
    }

    ROLES {
        uuid id PK
        text name
        boolean is_system
        jsonb metadata
    }

    USER_ROLES {
        uuid id PK
        uuid user_id
        uuid role_id
        uuid granted_by
        timestamptz expires_at
    }

    RESOURCE_POLICIES {
        uuid id PK
        uuid role_id
        text resource_type
        text resource_name
        text[] actions
        jsonb conditions
        text effect
        int priority
    }

    TENANT_DATABASES {
        uuid id PK
        text tenant_id
        text engine
        text name
        bytea connection_enc
    }

    SCHEMA_REGISTRY {
        uuid id PK
        uuid database_id
        text name
        text engine
        jsonb columns
        boolean enable_rls
    }
```
### PostgreSQL: RLS isolation

Isolation is delegated to the database itself.

Simplified example:
```sql
CREATE POLICY projects_owner_crud ON public.projects
  FOR ALL USING (
    auth.uid()::text = owner_id
  )
  WITH CHECK (
    auth.uid()::text = owner_id
  );
```
On external databases created by `schema-service`, the logic is adapted to use the context injected via `current_setting('app.current_user_id')`.

### Automatically generated external tables

When `schema-service` creates an external PostgreSQL table, it adds as standard:

- `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
- `owner_id UUID NOT NULL`
- `created_at TIMESTAMPTZ DEFAULT now()`
- `updated_at TIMESTAMPTZ DEFAULT now()`

This choice makes it possible to impose a common foundation on all projects without requiring each developer to rethink their isolation strategy.

### MongoDB: document model and validator

MongoDB logic is based on:

- a mandatory `owner_id`;
- timestamps;
- JSON Schema validators;
- a filtered CRUD on the API side.

Typical logic diagram:
```mermaid
flowchart TD
    DOC[Document métier] --> OWNER[owner_id]
    DOC --> DATA[champs métier]
    DOC --> CREATED[created_at]
    DOC --> UPDATED[updated_at]
```
### Why the multilingual choice is relevant

| Need | PostgreSQL | MongoDB |
| ------------------------------- | ------------------------- | ------------------------ |
| Strict relational data | Great | Medium |
| Flexible scheme | Medium | Great |
| Native RLS | Great | Non-native |
| Self-generated APIs | Excellent with PostgREST | Requires custom service |
| Change streams / real time | Yes via dedicated mechanisms | Great |

The project therefore does not force a single model. It chooses the right engine depending on the nature of the data.

### External database register

The generic factory backend takes on its full meaning with `tenant_databases`.

Process :
```mermaid
sequenceDiagram
    participant U as Utilisateur
    participant AR as adapter-registry
    participant PG as PostgreSQL système
    participant QR as query-router
    participant EXT as Base externe

    U->>AR: Enregistre une base (engine + name + connection_string)
    AR->>AR: Chiffre la chaîne de connexion
    AR->>PG: Stocke dans tenant_databases
    U->>QR: Demande une requête générique
    QR->>AR: Récupère la connexion via token service interne
    AR-->>QR: Retourne engine + connection_string déchiffrée
    QR->>EXT: Exécute l'opération
    EXT-->>QR: Résultat
```
### 5.3 API / Routes

The project API is deliberately structured by cross-functional domains rather than by specific business logic.

#### Main roads exposed via Kong

| Method | External route | Services | Description | Auth Required |
| --------------------- | --------------------------------------- | ----------------- | ------------------------------------------------ | ---------------------------- |
| POST | `/auth/v1/signup` | GoTrue | user registration | apikey |
| POST | `/auth/v1/token` | GoTrue | connection and JWT | apikey |
| GET | `/rest/v1/...` | PostgREST | REST access to PostgreSQL tables | apikey + JWT according to resource |
| GET/POST/PATCH/DELETE | `/mongo/v1/collections/:name/documents` | mongo-api | Generic CRUD MongoDB | apikey + JWT |
| GET | `/mongo/v1/admin/collections` | mongo-api | list of collections | apikey + JWT |
| POST | `/query/v1/query/:dbId/tables/:table` | query-router | universal query on a registered database | apikey + JWT |
| GET | `/query/v1/query/:dbId/tables` | query-router | list of tables / collections of a registered database | apikey + JWT |
| POST | `/schemas/v1/schemas` | service-schema | creation of table / collection | apikey + JWT |
| GET | `/schemas/v1/schemas` | service-schema | list of saved schemas | apikey + JWT |
| DELETE | `/schemas/v1/schemas/:id` | service-schema | deleting a schema | apikey + JWT |
| POST | `/admin/v1/databases` | adapter-registry | registering an external database | apikey + JWT |
| GET | `/admin/v1/databases` | adapter-registry | list of user databases | apikey + JWT |
| POST | `/permissions/v1/permissions/check` | permission-engine | access verification | apikey + JWT |
| GET | `/permissions/v1/policies` | permission-engine | reading policies | apikey + JWT admin |
| POST | `/storage/v1/sign/:bucket/*` | storage-router | Presigned URL | apikey + JWT |
| POST | `/email/v1/send` | email-service | sending email | apikey + JWT |
| GET | `/realtime/v1/...` | realtime | real time | apikey + JWT |

### Examples of payloads

#### Registering an external database
```json
{
  "engine": "postgresql",
  "name": "customer-crm",
  "connection_string": "postgres://user:pass@host:5432/crm"
}
```
#### Creating a PostgreSQL schema
```json
{
  "name": "contacts",
  "engine": "postgresql",
  "database_id": "550e8400-e29b-41d4-a716-446655440000",
  "enable_rls": true,
  "columns": [
    { "name": "first_name", "type": "text", "nullable": false },
    { "name": "last_name", "type": "text", "nullable": false },
    { "name": "email", "type": "text", "nullable": false, "unique": true }
  ]
}
```
#### MongoDB universal query
```json
{
  "action": "find",
  "filter": { "status": "active" },
  "sort": { "created_at": "desc" },
  "limit": 20,
  "offset": 0
}
```
#### PostgreSQL universal query
```json
{
  "action": "insert",
  "data": {
    "title": "First note",
    "content": "Generic backend factory demo"
  }
}
```
### Why these roads are powerful

Because they are based on **engines** and not on fixed business cases:

- the same endpoint serves several tables;
- the same service works for several projects;
- the security logic remains uniform;
- maintenance focuses on primitives, not duplicates.

---

## 6. Security

Security is not a late addition to this repository: it is an **architecture axis**.

### Overview of security layers
```mermaid
flowchart TD
    A[Client] --> B[WAF / ModSecurity]
    B --> C[Kong Gateway]
    C --> D[JWT + API Key + Plugins]
    D --> E[Services NestJS]
    E --> F[Validation DTO + Guards]
    F --> G[RLS PostgreSQL / owner isolation Mongo]
    G --> H[Chiffrement des secrets + Vault]
```
### 6.1 Front-End Security Measures

Even if the front is not in this repository, the client-side security rules are clearly induced by the architecture.

| Vulnerability | Measure put in place | Application to the project |
| --------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| XSS | Avoid `innerHTML`, use escape and make safe | Any client consuming the APIs must display the data securely |
| CSRF | Use of JWT Bearer and `apikey` rather than implicit session cookies | Calls are explicitly authenticated |
| Token theft | Conservative client-side storage, limited lifetime, refresh token rotation | Managed by GoTrue and Customer |
| Exposure of secrets | No DB, SMTP or S3 secrets on the front side | Any sensitive operation goes through the services |
| Side access | Headers and claims managed by Kong, not by the client directly | The front does not forge its own identity |
| Upload dangerous | Server-side generated presigned URL | Client does not obtain S3 credentials |

### 6.2 Monitoring of Vulnerabilities

Reference sources relevant to this project:

- OWASP Top 10;
- Kong, PostgreSQL, MongoDB, GoTrue documentation;
- Docker security guides;
- CVE notice of the images used;
- Node.js / NestJS best practices.

### Vulnerabilities taken into account

| Vulnerability | Risk | Answer in architecture |
| ------------------------------- | ------------------------------- | -------------------------------------------------------------- |
| Auth Bypass | Unauthorized access to services | Kong enforces `key-auth` and `jwt` |
| Falsification of claims | Identity theft | User headers come from the gateway, not the client |
| SQL Injection | Alteration of queries | Validation of names, use of parameters, controlled operations |
| Mongo injection | Dangerous filters | Removing `$where`, cleaning sensitive keys |
| Lateral climbing between tenants | Data leak | RLS SQL, `owner_id` Mongo, policies |
| Leaked connection strings | Compromise of external databases | AES-256-GCM + encrypted storage |
| Bruteforce / API abuse | Denial of service | Rate limits Kong |
| Malicious upload | Abusive content | Controlled presigning and isolation by user prefix |
| Overexposure admin | Back office access | `ip-restriction`, roles, service keys |

### 6.3 Back-end security measures

#### 1. WAF front-end

The `waf` service adds a first barrier against certain classes of known HTTP attacks.

#### 2. Gateway with global policies

Kong applies:

- API key control;
- JWT validation;
- security headers;
- query correlation;
- payload size;
- rate limiting.

#### 3. Strict input validation

NestJS services use `class-validator` and `class-transformer` via a global pipe.

#### 4. Guards and roles

- `AuthGuard`;
- `RolesGuard`;
- `ServiceTokenGuard`.

#### 5. Data isolation

- PostgreSQL: `ROW LEVEL SECURITY`;
- MongoDB: systematic filtering by `owner_id` in custom services;
- external databases: context `app.current_user_id` propagated for the generated tables.

#### 6. Encryption of sensitive secrets

External connection strings are never stored in the clear.

#### 7. Environment Secrets

The `generate-env.sh` script makes a `.env` with random secrets for local development.

Representative extract:
```bash
JWT_SECRET="$(openssl rand -hex 32)"
VAULT_ENC_KEY="$(openssl rand -hex 16)"
MINIO_ROOT_PASSWORD="$(openssl rand -hex 16)"
```
#### 8. Automated verification

The `validate-all.sh` script executes:

- shell verification;
- JavaScript verification;
- Docker Compose validation;
- control of secrets;
- scanning hardcoded secrets.

### 6.4 Why this security is suitable for a generic backend

A generic architecture is more exposed than a closed business back-end, because it manipulates reusable primitives. It is therefore necessary to secure the **frame** itself:

- standardize the entries;
- centralize auth;
- partition the tenants;
- control request sizes;
- protect secrets;
- govern access by roles and policies.

The project responds to this in a coherent manner across the entire chain.

---

## 7. Trial Game

The most representative functionality of the project is the following scenario:

> **register an external database, create a generic schema there, then query it via the query-router without writing a specific endpoint.**

### Summary view of the scenario
```mermaid
flowchart LR
    A[Register DB] --> B[Create Schema]
    B --> C[Insert Data]
    C --> D[Query Data]
    D --> E[Observe Isolation]
```
### Nominal case

| # | Input data | Expected data | Data obtained | Gap |
| --- | -------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------- | ----- |
| 1 | Registering a valid external PostgreSQL database | The database is stored encrypted in `tenant_databases` | Compliant expected | None |
| 2 | Creation of a `contacts` table via `schema-service` | Table created with `id`, `owner_id`, timestamps, RLS | Compliant expected | None |
| 3 | Insert via `query-router` | Row created, `owner_id` injected automatically | Compliant after correction | None |
| 4 | Reading by the same user | Return of user-specific lines | Compliant | None |
| 5 | Reading by another user | No line leaks | Compliant | None |

### Error case

| # | Input data | Expected data | Data obtained | Gap |
| --- | ------------------------------------ | --------------------- | ---------------- | ----- |
| 6 | Invalid table name | Reject with error 400 | Compliant | None |
| 7 | SQL type not supported in schema | Reject with error 400 | Compliant | None |
| 8 | Unknown action in `query-router` | Reject with error 400 | Compliant | None |
| 9 | JWT absent | Refusal of access | Compliant | None |
| 10 | API key missing | Rejection by Kong | Compliant | None |

### Analysis

This scenario demonstrates the fundamental value of the project:

- the structure is created without a business code;
- safety is not forgotten;
- the engine works for different projects;
- the operation remains unified.

---

## 8. Installation & Use

### 8.1 Prerequisites

Before you start:

- DockerEngine;
- Docker Compose v2;
-Bash;
- OpenSSL;
- Node.js if you want to launch TypeScript validations outside containers;
- available ports: `8000`, `5432`, `27017` and others depending on profiles.

### 8.2 Installation
```bash
# 1. Cloner le dépôt
git clone <url-du-repo>
cd mini-baas-infra

# 2. Générer les variables d'environnement
bash scripts/generate-env.sh

# 3. (Optionnel) Installer les dépendances du monorepo NestJS
cd src
npm install
cd ..

# 4. Vérifier la configuration
bash scripts/validate-all.sh
```
### 8.3 Project Launch

#### Starting the main database
```bash
make up
```
#### Getting started with additional services
```bash
make all-full
```
#### Health check
```bash
make health
```
#### Logs
```bash
make logs
make logs SERVICE=kong
```
#### Stop
```bash
make down
```
### Common ports and access points

| Services | URL/Port |
| ---------------------------------- | ----------------------------- |
| Gateway | `http://localhost:8000` |
| PostgreSQL | `localhost:5432` |
| MongoDB | `localhost:27017` |
| Kong Admin | `localhost:8001` |
| Prometheus (profile observability) | `http://localhost:9090` |
| Grafana (profile observability) | `http://localhost:3030` |
| Studio (profile extras) | according to profile and configuration |

### Recommended boot order for demonstration

1. generate `.env`;
2. `make up`;
3. check health;
4. create an account via `/auth/v1`;
5. test PostgREST or mongo-api;
6. register an external database;
7. create a schema;
8. run wildcard queries.

### 8.4 Service-by-service startup sequence

This subsection explains the system startup as a chain of dependencies. In a distributed architecture, the order of availability is not a detail: it conditions the reproducibility of the environment and the stability of the launch.
```mermaid
flowchart TD
  A[postgres] --> B[db-bootstrap]
  A --> C[gotrue]
  A --> D[postgrest]
  A --> E[permission-engine]
  A --> F[adapter-registry]
  A --> G[schema-service]

  H[mongo-keyfile] --> I[mongo]
  I --> J[mongo-init]
  I --> K[mongo-api]

  C --> L[kong]
  D --> L
  K --> L
  E --> L
  G --> L

  F --> M[query-router]
  L --> M
```
#### Step 1 — preparing secrets and environment variables

The system logically begins by generating or loading the `.env` file. This step fixes:

- PostgreSQL passwords;
- the shared `JWT_SECRET`;
- Kong API keys;
- MinIO secrets;
- MongoDB settings;
- inter-service service tokens.

Without this layer, multiple containers would not be able to converge to a common functional state.

#### Step 2 — starting primary persistence databases

The first building blocks to start are `postgres` and `mongo` because they support almost all other services.

Role of `postgres` at startup:

- host reference data;
- receive the roles;
- serve GoTrue, PostgREST, permission-engine and adapter-registry.

Role of `mongo` at startup:

- host local document collections;
- allow generic CRUD;
- serve realtime change streams.

#### Step 3 — bootstrap jobs

Two transient jobs are critical:

- `db-bootstrap` for PostgreSQL;
- `mongo-init` for the MongoDB replica set.

`db-bootstrap` prepares in particular:

- the `auth` scheme;
- demonstration tables;
- the `anon`, `authenticated`, `adaptor_registry_role` roles;
- RLS policies;
- registry and permissions tables.

`mongo-init` guarantees that the replica set exists, an important condition for certain real-time functionalities.

#### Step 4 — identity and internal data plane services

When PostgreSQL is ready and initialized, several services can start:

- `gotrue`;
- `postgrest`;
- `permission-engine`;
- `adaptor-registry`;
- `service-schema`.

When MongoDB is ready:

- `mongo-api` becomes available.

#### Step 5 — gateway and unified exposure

Kong only becomes truly useful once his key upstreams are reachable. Its late start in the chain avoids exposing an empty or incoherent facade.

#### Step 6 — services dependent on the gateway or other internal services

The `query-router` depends on both:

- the adapter register;
- the availability of the routing chain;
- the service token.

Its positioning at the end of the sequence is consistent.

#### Step 7 — optional services and observability

The services `minio`, `storage-router`, `prometheus`, `grafana`, `loki`, `promtail`, `studio`, `pg-meta`, `supavisor`, `trino` are then added depending on the activated profiles.

### 8.5 Complete cycle of main queries

This section documents the end-to-end behavior for the main technical flows. It is particularly useful in defense to show that we understand not only the components, but also their dynamic articulation.

#### 8.5.1 Cycle a SQL query via PostgREST
```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant G as JWT plugin
  participant P as PostgREST
  participant DB as PostgreSQL

  C->>K: GET /rest/v1/projects + apikey + Bearer JWT
  K->>G: Vérification JWT
  G-->>K: Claims valides
  K->>P: Forward request with auth context
  P->>DB: Requête SQL générée
  DB-->>P: Résultats filtrés par RLS
  P-->>K: JSON REST
  K-->>C: Réponse
```
**Analysis:** Here, the basic application logic does not live in a NestJS controller. API-table coupling is provided by PostgREST, and row security is supported by PostgreSQL.

#### 8.5.2 Cycle a MongoDB query via `mongo-api`
```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant M as mongo-api
  participant DB as MongoDB

  C->>K: POST /mongo/v1/collections/orders/documents
  K->>M: Headers utilisateur injectés
  M->>M: Validation DTO + AuthGuard
  M->>M: Injection owner_id + nettoyage payload
  M->>DB: insertOne / find / update / delete
  DB-->>M: Résultat
  M-->>K: Réponse normalisée
  K-->>C: Réponse finale
```
**Analysis:** here, unlike PostgREST, the proprietary protection layer is provided in the application service itself.

#### 8.5.3 Cycle of a query on an external database via `query-router`
```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant QR as query-router
  participant AR as adapter-registry
  participant E as SQL/Mongo engine
  participant X as External DB

  C->>K: POST /query/v1/query/:dbId/tables/:table
  K->>QR: user headers + service context
  QR->>AR: resolve database connection
  AR-->>QR: engine + decrypted connection string
  QR->>E: execute(action, data, filter, userId)
  E->>X: safe operation on external DB
  X-->>E: result set
  E-->>QR: normalized response
  QR-->>K: API response
  K-->>C: final response
```
**Analysis:** this flow is the strongest demonstration of the generic nature of the project, because it allows you to manipulate a remote database without creating a dedicated back-end.

#### 8.5.4 Schema creation cycle via `schema-service`
```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant SS as schema-service
  participant AR as adapter-registry
  participant X as External DB
  participant PG as schema_registry

  C->>K: POST /schemas/v1/schemas
  K->>SS: validated user request
  SS->>AR: fetch external DB connection
  AR-->>SS: engine + connection string
  SS->>X: CREATE TABLE / CREATE COLLECTION
  SS->>PG: Persist schema metadata
  SS-->>K: created result
  K-->>C: confirmation
```
#### 8.5.5 Object storage cycle via `storage-router`
```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant S as storage-router
  participant O as MinIO / S3

  C->>K: POST /storage/v1/sign/:bucket/*
  K->>S: authenticated request
  S->>S: prefix path with user id
  S->>O: generate presigned operation
  O-->>S: signed URL
  S-->>C: signedUrl + expiresAt
  C->>O: upload/download directly
```
**Analysis:** the backend does not transport the file itself in this stream; it delegates the transfer to object storage via a temporary authorization.

#### 8.5.6 Email sending cycle via `email-service`
```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant E as email-service
  participant SMTP as SMTP server

  C->>K: POST /email/v1/send
  K->>E: authenticated request
  E->>E: validate dto
  E->>SMTP: sendMail()
  SMTP-->>E: messageId
  E-->>C: message accepted
```
#### 8.5.7 Real-time cycle
```mermaid
sequenceDiagram
  participant C as Client
  participant K as Kong
  participant R as realtime
  participant PG as PostgreSQL
  participant MG as MongoDB

  C->>K: subscribe websocket/http realtime
  K->>R: forward connection
  R->>PG: watch relational changes
  R->>MG: watch document changes
  PG-->>R: event
  MG-->>R: event
  R-->>C: pushed change notification
```
**Analysis:** this flow transforms the backend into a reactive platform, not just transactional.

---

## 9. Risks, Limitations & Future Improvements

### 9.1 Current technical risks

| Risk | Description | Potential impact | Current/future response |
| ------------------------------ | ---------------------------------------------------------------- | --------------------------------- | -------------------------------------------------------- |
| Stack complexity | Multiplication of services to understand and exploit | Stronger learning curve | Documentation, Makefile, Compose profiles |
| Coupling to the gateway | Many feeds assume Kong available | Overall degradation if Kong falls | Healthchecks, declarative config, monitoring |
| Governance of external databases | A bad external database can have unexpected conventions | Difficulty of standardization | `schema-service`, type validation, central registry |
| SQL/Mongo heterogeneity | Two data models imply two security strategies | Complexity of reasoning | Encapsulation by dedicated engines |
| Generic exhibition area | A reusable backend exposes powerful primitives | Risks of abuse if poorly governed | API keys, JWT, rate limits, policies |

### 9.2 Functional limits

- absence of a unified administration interface dedicated to custom services;
- support voluntarily limited to certain generic operations;
- dependence on `owner_id` conventions for part of the isolation strategies;
- no custom generic GraphQL engine at this stage;
- no complete low-code functional management workflow;
- no multi-node high availability described in this repository.

### 9.3 Educational limits to be explained orally

For an exercise, it may be useful to specify that:

- the platform primarily aims to demonstrate architecture and integration;
- it is already very rich, but not everything is industrialized at the level of a global SaaS;
- the goal is not to replace all business developments, but to massively reduce repetitive developments.

### 9.4 Possible future improvements

| Axis | Improvement |
| -------------------- | ---------------------------------------------------------------------------------- |
| Governance | Dedicated UI for `adaptor-registry`, `schema-service`, `permission-engine` |
| Security | automated rotation of secrets, more in-depth audit trail |
| Data plane | support for other engines or enriched analytical operations |
| Developer experience | Official client SDK, consumer front-end templates |
| Observability | complete distributed correlation and specialized dashboards |
| Deployment | packaging Kubernetes / Helm / GitOps |
| Documentation | guides oriented by business use cases |

### 9.5 Strategic summary

The main compromise of the project is the following:

> it accepts higher infrastructure complexity to radically reduce the repetition of back-end developments on future projects.

This compromise is coherent if the platform is thought of as a transversal investment.

---

## 10. Glossary

| Term | Definition |
| ------------------ | ---------------------------------------------------------------------------------- |
| BaaS | Backend as a Service, platform providing shared back-end building blocks |
| RLS | Row-Level Security, PostgreSQL row-by-row security mechanism |
| DTO | Data Transfer Object, validated incoming/outgoing data structure |
| JWT | JSON Web Token, signed authentication token |
| API Gateway | Single point of entry that enforces policies, routing and security |
| Holding | Isolated logical entity in a multi-tenant system |
| ABAC | Attribute-Based Access Control, attribute-based authorization |
| RBAC | Role-Based Access Control, role-based authorization |
| Presigned URL | Signed temporary URL giving limited access to a storage object |
| Change Stream | MongoDB side change event flow |
| Declarative config | Configuration described in a file rather than dynamically built by hand |
| Monorepo | Single repository containing multiple applications and libraries |
| Healthcheck | Checking the status of a service by the orchestrator |
| Upstream | Target service behind the gateway |
| Owner isolation | Strategy to filter data by owner |

---

## 11. Project Structure
```text
mini-baas-infra/
│
├── docker-compose.yml                # orchestration principale
├── docker-bake.hcl                   # build multi-targets
├── Makefile                          # commandes d'exploitation
├── README.md                         # documentation racine
├── docs/                             # documentation détaillée
├── config/                           # configs observabilité
├── docker/                           # contrats et services Docker spécifiques
├── scripts/                          # bootstrap, tests, validations, migrations
│
├── src/                              # monorepo NestJS
│   ├── Dockerfile                    # Dockerfile unifié des apps
│   ├── nest-cli.json                 # définition monorepo
│   ├── tsconfig.json                 # config TypeScript
│   ├── apps/
│   │   ├── adapter-registry/
│   │   ├── query-router/
│   │   ├── schema-service/
│   │   ├── permission-engine/
│   │   ├── mongo-api/
│   │   ├── storage-router/
│   │   └── email-service/
│   └── libs/
│       ├── common/
│       ├── database/
│       └── health/
│
└── playground/                       # sandbox éventuel de démonstration
```
### Reading structure by responsibilities

| File | Responsibility |
| ----------------- | -------------------------------------------- |
| `src/apps` | application logic of custom microservices |
| `src/libs` | transverse reusable components |
| `docker/services` | services or infrastructure configurations |
| `scripts` | automation and validation |
| `docs` | documentation knowledge base |
| `config` | observability and provisioning |

---

## 12. Source File Mapping

This mapping links the main files in the repository to their architectural role. It has a double use:

- facilitate the defense by showing where each responsibility lives;
- accelerate maintenance by providing an architecture-oriented reading.

### 12.1 Mapping NestJS applications

| File | Architectural role |
| -------------------------------------------------------------------------------- | ------------------------------------------------ |
| `src/apps/adapter-registry/src/main.ts` | HTTP bootstrap, logger, Swagger, global pipeline |
| `src/apps/adapter-registry/src/app.module.ts` | registry service root composition |
| `src/apps/adapter-registry/src/health.controller.ts` | health of the service |
| `src/apps/adapter-registry/src/crypto/crypto.module.ts` | encryption component exposure |
| `src/apps/adapter-registry/src/crypto/crypto.service.ts` | AES-256-GCM encryption/decryption |
| `src/apps/adapter-registry/src/databases/databases.module.ts` | registry functional module |
| `src/apps/adapter-registry/src/databases/databases.controller.ts` | database recording/reading endpoints |
| `src/apps/adapter-registry/src/databases/databases.service.ts` | ledger business logic and encrypted storage |
| `src/apps/adapter-registry/src/databases/dto/register-database.dto.ts` | registration validation contract |
| `src/apps/query-router/src/main.ts` | query router bootstrap |
| `src/apps/query-router/src/app.module.ts` | service assembly |
| `src/apps/query-router/src/health.controller.ts` | query-router health |
| `src/apps/query-router/src/query/query.module.ts` | functional query module |
| `src/apps/query-router/src/query/query.controller.ts` | execution and listing endpoints |
| `src/apps/query-router/src/query/query.service.ts` | registry and engine orchestration |
| `src/apps/query-router/src/query/dto/query.dto.ts` | unified contract for query operations |
| `src/apps/query-router/src/engines/postgresql.engine.ts` | secure generic PostgreSQL engine |
| `src/apps/query-router/src/engines/mongodb.engine.ts` | secure generic MongoDB engine |
| `src/apps/schema-service/src/main.ts` | schema service bootstrap |
| `src/apps/schema-service/src/app.module.ts` | root assembly |
| `src/apps/schema-service/src/health.controller.ts` | health of the service |
| `src/apps/schema-service/src/schemas/schemas.module.ts` | business schema module |
| `src/apps/schema-service/src/schemas/schemas.controller.ts` | create/list/delete endpoints |
| `src/apps/schema-service/src/schemas/schemas.service.ts` | DDL orchestration and registry |
| `src/apps/schema-service/src/schemas/dto/schema.dto.ts` | definition of incoming schemas |
| `src/apps/schema-service/src/engines/postgres-schema.engine.ts` | creating/deleting PostgreSQL tables |
| `src/apps/schema-service/src/engines/mongo-schema.engine.ts` | creating/deleting MongoDB collections |
| `src/apps/permission-engine/src/main.ts` | permissions engine bootstrap |
| `src/apps/permission-engine/src/app.module.ts` | service composition |
| `src/apps/permission-engine/src/health.controller.ts` | health of the service |
| `src/apps/permission-engine/src/permissions/permissions.module.ts` | permissions evaluation module |
| `src/apps/permission-engine/src/permissions/permissions.controller.ts` | verification and roles endpoints |
| `src/apps/permission-engine/src/permissions/permissions.service.ts` | ABAC/RBAC verification logic |
| `src/apps/permission-engine/src/permissions/dto/permission.dto.ts` | DTO of check and

of assignment |
| `src/apps/permission-engine/src/policies/policies.module.ts` | policy management module |
| `src/apps/permission-engine/src/policies/policies.controller.ts` | policy CRUD endpoints |
| `src/apps/permission-engine/src/policies/policies.service.ts` | persistence and reading of policies |
| `src/apps/permission-engine/src/policies/dto/policy.dto.ts` | policy contract |
| `src/apps/mongo-api/src/main.ts` | Mongo data plane bootstrap |
| `src/apps/mongo-api/src/app.module.ts` | Mongo global composition |
| `src/apps/mongo-api/src/health.controller.ts` | health of the service |
| `src/apps/mongo-api/src/collections/collections.module.ts` | document CRUD module |
| `src/apps/mongo-api/src/collections/collections.controller.ts` | endpoints CRUD collections |
| `src/apps/mongo-api/src/collections/collections.service.ts` | owner-scoped Mongo logic |
| `src/apps/mongo-api/src/collections/dto/collection.dto.ts` | Documentary DTOs |
| `src/apps/mongo-api/src/admin/admin.module.ts` | Mongo admin module |
| `src/apps/mongo-api/src/admin/admin.controller.ts` | endpoints admin collection/schema/index |
| `src/apps/mongo-api/src/admin/admin.service.ts` | validator and index management |
| `src/apps/mongo-api/src/admin/dto/admin.dto.ts` | Mongo admin DTOs |
| `src/apps/storage-router/src/main.ts` | storage service bootstrap |
| `src/apps/storage-router/src/app.module.ts` | service composition |
| `src/apps/storage-router/src/health.controller.ts` | health of the service |
| `src/apps/storage-router/src/storage/storage.module.ts` | storage functional module |
| `src/apps/storage-router/src/storage/storage.controller.ts` | presigning endpoint |
| `src/apps/storage-router/src/storage/storage.service.ts` | generation of signed URLs |
| `src/apps/storage-router/src/storage/dto/presign.dto.ts` | presignature contract |
| `src/apps/email-service/src/main.ts` | email service bootstrap |
| `src/apps/email-service/src/app.module.ts` | root composition |
| `src/apps/email-service/src/health.controller.ts` | health of the service |
| `src/apps/email-service/src/mail/mail.module.ts` | email module |
| `src/apps/email-service/src/mail/mail.controller.ts` | sending endpoint |
| `src/apps/email-service/src/mail/mail.service.ts` | SMTP integration |
| `src/apps/email-service/src/mail/dto/send-email.dto.ts` | email sending contract |

### 12.2 Mapping shared libraries

| File | Architectural role |
| ---------------------------------------------------------------- | ------------------------------------------------ |
| `src/libs/common/src/index.ts` | barrel export of the common base |
| `src/libs/common/src/decorators/current-user.decorator.ts` | user context extraction |
| `src/libs/common/src/guards/auth.guard.ts` | validation of user headers injected by Kong |
| `src/libs/common/src/guards/roles.guard.ts` | enforcement of roles |
| `src/libs/common/src/guards/service-token.guard.ts` | cross-service auth or user fallback |
| `src/libs/common/src/interfaces/user-context.interface.ts` | common type of user context |
| `src/libs/common/src/config/env.validation.ts` | configuration validation |
| `src/libs/common/src/filters/all-exceptions.filter.ts` | normalization of errors |
| `src/libs/common/src/interceptors/correlation-id.interceptor.ts` | propagation of correlation IDs |
| `src/libs/common/src/pipes/validation.pipe.ts` | global DTO validation policy |
| `src/libs/database/src/index.ts` | database base exports |
| `src/libs/database/src/postgres/postgres.module.ts` | shared PostgreSQL module |
| `src/libs/database/src/postgres/postgres.service.ts` | PostgreSQL pools, adminQuery, tenantQuery |
| `src/libs/database/src/mongo/mongo.module.ts` | shared Mongo module |
| `src/libs/database/src/mongo/mongo.service.ts` | shared Mongo client |
| `src/libs/health/src/index.ts` | health exports |
| `src/libs/health/src/health.module.ts` | dynamic health module |
| `src/libs/health/src/health.controller.ts` | standardized live/ready endpoints |

### 12.3 Mapping of major infrastructure files

| File | Architectural role |
| ------------------------------------ | -------------------------------------------------- |
| `docker-compose.yml` | global orchestration of the platform |
| `docker-bake.hcl` | multi-image parallel build strategy |
| `Makefile` | developer/ops front of house |
| `scripts/db-bootstrap.psql` | structuring initialization of PostgreSQL |
| `scripts/generate-env.sh` | secure generation of `.env` |
| `scripts/validate-all.sh` | fast local validation before execution or commit |
| `docker/services/kong/conf/kong.yml` | declarative definition of the gateway |
| `src/Dockerfile` | unified build of NestJS microservices |
| `src/nest-cli.json` | Nest monorepo definition |
| `src/tsconfig.json` | common TypeScript base |

### 12.4 Documentary and operational mapping

| File/Folder | Architectural role |
| -------------------------------------------------- | ------------------------------- |
| `docs/README.md` | documentation index |
| `docs/Insfrastructure.md` | infrastructure overview |
| `docs/Kong-Gateway-Configuration.md` | gateway detail |
| `docs/Kong-Database-Authentication-Integration.md` | auth/RLS string |
| `docs/Mongo-Service-Validation.md` | validation of the Mongo data plane |
| `docs/Partner-Demo-Runbook.md` | demonstration scenario |
| `config/prometheus/` | metric configuration |
| `config/grafana/` | provisioning dashboards |
| `config/loki/` | configuration logs |
| `config/promtail/` | Docker log collection |

---

## 13. Appendices

### Appendix A – Complete Authentication Cycle Diagram
```mermaid
sequenceDiagram
    participant U as Utilisateur
    participant FE as Front-end
    participant K as Kong
    participant GT as GoTrue
    participant API as Services
    participant PG as PostgreSQL / MongoDB

    U->>FE: Saisie email + mot de passe
    FE->>K: POST /auth/v1/token
    K->>GT: Forward auth request
    GT-->>FE: access token + refresh token
    FE->>K: Requête API avec apikey + Bearer JWT
    K->>K: key-auth + jwt validation
    K->>API: Injecte X-User-Id / X-User-Role
    API->>PG: Requête sécurisée
    PG-->>API: Données filtrées
    API-->>FE: Réponse JSON
```
### Appendix B – External Schema Creation Cycle
```mermaid
sequenceDiagram
    participant U as User
    participant SS as schema-service
    participant AR as adapter-registry
    participant DB as External DB
    participant REG as schema_registry

    U->>SS: POST /schemas with CreateSchemaDto
    SS->>AR: GET /databases/:id/connect
    AR-->>SS: engine + connection_string
    SS->>DB: CREATE TABLE / CREATE COLLECTION
    SS->>REG: INSERT metadata in schema_registry
    SS-->>U: Schema created
```
### Appendix C – Universal Query Cycle
```mermaid
sequenceDiagram
    participant U as User
    participant QR as query-router
    participant AR as adapter-registry
    participant ENG as Engine SQL/Mongo
    participant DB as External Database

    U->>QR: POST query request
    QR->>AR: fetchConnection(dbId, userId)
    AR-->>QR: engine + decrypted connection string
    QR->>ENG: execute(action, filter, data, userId)
    ENG->>DB: parameterized query / filtered document op
    DB-->>ENG: result set
    ENG-->>QR: normalized payload
    QR-->>U: rows + rowCount
```
### Appendix D – Unified DTO extract for the query-router
```typescript
export class ExecuteQueryDto {
  @IsEnum([
    "select",
    "insert",
    "update",
    "delete",
    "find",
    "insertOne",
    "updateMany",
    "deleteMany",
  ])
  action!: string;

  @IsOptional()
  @IsObject()
  data?: Record<string, unknown>;

  @IsOptional()
  @IsObject()
  filter?: Record<string, unknown>;
}
```
This DTO illustrates the logic of standardization: a common envelope, several engines.

### Appendix E – Why this project is a general back-end architecture

The project deserves the label of **general backend** for the following reasons:

1. it is not linked to a particular profession;
2. it provides universal primitives (auth, data, storage, email, realtime);
3. it can be plugged into several different projects;
4. it supports multiple persistence engines;
5. it creates the schemas and queries the databases without a specific endpoint;
6. it applies generic security rules;
7. it can be industrialized thanks to Docker Compose and its scripts.

### Appendix F – General conclusion

This architecture is not just a technical stack of juxtaposed services. It is a **coherent system**, designed like a backend factory:

- the gateway protects and standardizes;
- authentication unifies identity;
- data planes expose data without repetitive business code;
- the registry, the query router and the schema generator make the platform adaptable to other projects;
- the permissions engine provides governance;
- cross-functional services cover current needs;
- observability and automation tools make everything usable.

In summary, this solution constitutes a **highly reusable technical foundation**, secure and modular, capable of serving as a back-end for many projects without starting from scratch.

---

_Document written as part of an architectural and technical documentation exercise._
_Version based on filing status as of April 12, 2026._
