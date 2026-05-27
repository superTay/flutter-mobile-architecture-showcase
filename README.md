<!--
================================================================
README del repo github.com/superTay/flutter-mobile-architecture-showcase
================================================================

Importante:
- El archivo logo-movil.svg vive en la RAÍZ del repo (no en assets/).
  Por eso el <img src="logo-movil.svg"> NO lleva prefijo de carpeta.
- Si lo mueves a assets/ en el futuro, actualiza la ruta a "assets/logo-movil.svg".

Para usarlo:
1. Asegúrate de que logo-movil.svg está en la raíz del repo (ya lo tienes).
2. En GitHub, edita el README del repo, borra todo el contenido actual
   y pega lo de abajo (desde la línea <div align="center"> hasta el final).
3. Commit a main.

Cambios respecto a la versión anterior:
- Logo nuevo al inicio (160px, clicable hacia la web companion)
- Sub-tagline + badges (Flutter 19, Dart 3, Riverpod, Drift, Supabase,
  TestFlight aprobado, licencia)
- Botones CTA: "Web companion (live)" + "Author's portfolio"
- Tabla "KonquerAI ecosystem" al final con cross-links a los otros 2 repos
- Footer con tres links (web companion · portfolio · @superTay)
- TODA la parte técnica (Why these files, Architecture, Engineering decisions,
  What was changed, Stack, License) queda intacta — no se toca una coma
================================================================
-->

<div align="center">

<a href="https://app.konquerai.com">
  <img src="logo-movil.svg" alt="KonquerAI Mobile" width="160" />
</a>

# Flutter Mobile Architecture — Showcase

**The mobile companion to a production invoicing & quoting SaaS for self-employed tradespeople in Spain.**

A curated, sanitized extract of selected patterns from a private production Flutter app I built solo — distributed via TestFlight, with a build approved by Apple's review.

<p>
  <a href="https://app.konquerai.com"><img src="https://img.shields.io/badge/Web%20companion-app.konquerai.com-3FCF8E?style=for-the-badge&logo=vercel&logoColor=white" alt="Web companion (live)"></a>
  <a href="https://christian-marzal-portfolio.vercel.app/"><img src="https://img.shields.io/badge/Author's%20portfolio-christian--marzal-1a365d?style=for-the-badge&logoColor=white" alt="Author's portfolio"></a>
</p>

![Flutter](https://img.shields.io/badge/Flutter-3-02569B?logo=flutter&logoColor=white)
![Dart](https://img.shields.io/badge/Dart-3-0175C2?logo=dart&logoColor=white)
![Riverpod](https://img.shields.io/badge/Riverpod-State-0553B1?logoColor=white)
![go_router](https://img.shields.io/badge/go__router-Auth%20guard-3DDC84?logoColor=white)
![Drift](https://img.shields.io/badge/Drift-SQLite%20offline-003B57?logo=sqlite&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-Auth%20%2B%20Realtime-3FCF8E?logo=supabase&logoColor=white)
![TestFlight](https://img.shields.io/badge/TestFlight-build%20approved-007AFF?logo=appstore&logoColor=white)
![License](https://img.shields.io/badge/license-source--available-orange)

</div>

> ⚠️ **This is not a runnable app.** It is a small set of representative files,
> chosen because they show interesting engineering decisions *without* exposing
> business logic, real endpoints, database schema or credentials. Product name,
> table names, API routes and keys have been replaced with neutral placeholders.
> The full app (~28k lines of Dart, 111 files) stays in a private repository.

---

## Why these files

The interesting parts of this app aren't the screens — they're the **data layer
decisions**: how a client with *no backend of its own* orchestrates two external
backends safely, stays usable offline, and keeps financial math exact.

| File | Pattern it demonstrates |
|------|-------------------------|
| [`lib/core/utils/fiscal.dart`](lib/core/utils/fiscal.dart) | Exact financial math — Spanish VAT/withholding, **`decimal`-based rounding to 2 decimals** (not binary-float arithmetic, to avoid representation drift), NIF/CIF/NIE validation with check-letter algorithm. Ported from the web app's logic. |
| [`test/fiscal_test.dart`](test/fiscal_test.dart) | Unit tests for the fiscal module — rounding edge cases, VAT/IRPF, ID validation. |
| [`lib/data/services/api_service.dart`](lib/data/services/api_service.dart) | **Dio HTTP client** with a session-key interceptor, per-endpoint timeout overrides, smart retry with backoff, and centralized human-readable error mapping. |
| [`lib/data/services/auth_service.dart`](lib/data/services/auth_service.dart) | **Dual-auth pattern**: provider auth (JWT) + a separate internal session token for the write backend, with automatic token renewal (TTL/margin) and self-healing on app restart. |
| [`lib/data/services/cache_database.dart`](lib/data/services/cache_database.dart) | **Offline cache** with `drift`/SQLite using raw SQL (no codegen), feeding a stale-while-revalidate strategy. |
| [`lib/core/config/app_config.example.dart`](lib/core/config/app_config.example.dart) | Config template — copy to `app_config.dart` and fill with your own values. |

---

## Architecture in one picture

```
            ┌──────────────────────────── Flutter client ───────────────────────────┐
            │                                                                         │
   reads    │   Riverpod state  ──►  Repositories  ──►  ApiService (Dio)              │  writes
 ◄──────────┼───────────────────────────────────────────────────────────────────────┼──────────►
            │         │                                   │                           │
            │         ▼                                   ▼                           │
            │   Drift cache (SQLite)              session-key interceptor             │
            │   stale-while-revalidate                                                │
            └─────────┬───────────────────────────────────┬───────────────────────────┘
                      │                                   │
                      ▼                                   ▼
         ┌────────────────────────┐          ┌──────────────────────────────┐
         │  Provider backend       │          │  Automation/write backend     │
         │  (Auth + RLS reads +    │          │  (webhooks; all business      │
         │   Realtime)             │          │   writes go through here)     │
         └────────────────────────┘          └──────────────────────────────┘
```

Two key rules the codebase enforces:

1. **Reads** go straight to the provider backend, trusting row-level security by
   `user_id`. **Writes** of business entities go *only* through the automation
   backend, carrying an internal `session_key` — never the provider JWT.
2. The internal `session_key` is auto-renewed (e.g. 7-day TTL, renew when within
   a 2-day margin) and self-heals on restart so a stale local token realigns with
   the database without forcing the user to log out and back in.

## Notable engineering decisions

- **No codegen for state or DB.** A hard version conflict in the `analyzer`
  dependency between the Riverpod and Drift code generators made codegen
  impractical. Solution: manual Riverpod providers + Drift's low-level raw-SQL
  API. Trade-off: more boilerplate, zero dependency-pin deadlock.
- **`decimal` for money, never `double` arithmetic in widgets.** All rounding is
  centralized in one module and computed with the `decimal` package to avoid
  binary-float representation errors, mirroring the web app's fiscal logic.
- **Offline-first reads.** When connectivity drops, the UI serves the Drift cache
  and disables write actions instead of failing.

## What was changed for this public extract

- Product/brand name → neutral (`field_app`).
- Real backend URLs and keys → placeholders in `app_config.example.dart`.
- Database table names → generic (`profiles`, `sessions`, `accounts`, `*_cache`).
- API route names → generic (`/quotes`, `/invoices`, …).
- Strongly-typed `freezed` models → `Map<String, dynamic>` in the auth flow, to
  keep the extract self-contained.
- Endpoint-specific methods (signed-URL PDF proxy, account deletion, multipart
  chat) were removed to avoid revealing real contracts.

## Stack

Flutter · Dart 3 · Riverpod · go_router · Supabase (auth/reads/realtime) ·
**n8n automation backend (all business writes)** · Dio + dio_smart_retry ·
Drift/SQLite · flutter_secure_storage · decimal · freezed.

---

## The KonquerAI ecosystem (all built solo)

| Repo | What it is |
|------|------------|
| **Flutter mobile app** (this repo) | The mobile companion (TestFlight-approved): offline-first cache, dual-auth, fiscal math ported 1:1 for cross-language parity. |
| [💻 React web dashboard](https://github.com/superTay/react-web-architecture-showcase) | React 19 + TypeScript front end — the source-of-truth contracts the mobile mirrors. Live at [app.konquerai.com](https://app.konquerai.com). |
| [⚙️ Automation backend](https://github.com/superTay/konquerai-automation-backend) | 17 n8n workflows: OCR, conversational AI assistants, email-to-invoice ingestion, PDF generation, VeriFactu-style hash chaining. |

## License

Source-available for **portfolio and evaluation only** — not open source.
See [LICENSE](LICENSE). © 2026 Christian Marzal Della Rovere. All rights reserved.

---

<p align="center">
  <sub>Built solo · <a href="https://app.konquerai.com">web companion</a> · <a href="https://christian-marzal-portfolio.vercel.app/">author's portfolio</a> · <a href="https://github.com/superTay">@superTay</a></sub>
</p>
