# Flutter Mobile Architecture — Showcase

A **curated, sanitized extract** of selected patterns from a private production
Flutter app I built solo: a mobile invoicing/quoting tool for self-employed
tradespeople in Spain (painters, electricians, plumbers, builders). The app is
the mobile companion to an existing web SaaS — distributed via TestFlight, with
a build approved by Apple's review.

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

## License

Source-available for **portfolio and evaluation only** — not open source.
See [LICENSE](LICENSE). © 2026 Christian Marzal Della Rovere. All rights reserved.
