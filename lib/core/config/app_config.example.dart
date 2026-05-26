// ============================================================
// Environment Configuration — TEMPLATE
// ============================================================
// Copy this file to `app_config.dart` and fill in your own values.
// `app_config.dart` is gitignored so real URLs/keys are never committed.
//
// Note: a provider "anon"/publishable key is designed to ship in the
// client, but you still should not publish your real project URL + key
// in a public repo — it invites abuse even when row-level security
// protects the data.
// ============================================================

/// Centralized configuration constants.
class AppConfig {
  AppConfig._();

  // ── Automation / write backend (webhooks) ──────────────────
  static const String apiBaseUrl = 'https://api.example.com/webhook';

  // ── Provider backend (auth / reads / realtime) ─────────────
  static const String providerUrl = 'https://YOUR_PROJECT.supabase.co';
  static const String providerAnonKey = 'YOUR_PUBLISHABLE_ANON_KEY';

  // ── Timeouts ───────────────────────────────────────────────
  static const Duration defaultTimeout = Duration(seconds: 30);
  static const Duration slowTimeout = Duration(seconds: 90);
  static const Duration connectTimeout = Duration(seconds: 15);

  // ── App info ───────────────────────────────────────────────
  static const String appName = 'Field App';
  static const String bundleId = 'com.example.fieldapp';
  static const String appVersion = '1.0.0';

  // ── Legal / compliance ─────────────────────────────────────
  static const String privacyPolicyUrl = 'https://example.com/privacy';
}
