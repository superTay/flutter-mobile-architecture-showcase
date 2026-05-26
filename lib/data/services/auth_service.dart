// ============================================================
// Auth Service — dual authentication
// ============================================================
//
// The app authenticates against TWO things:
//   1. The provider backend (email/password → JWT). Used for reads
//      protected by row-level security.
//   2. An internal `session_key` (a row in the `sessions` table) that
//      the write/automation backend understands. The JWT is NEVER sent
//      to the write backend.
//
// Login flow:
//   1. signInWithPassword(email, password)                 → JWT
//   2. lookup `profiles` by auth_user_id                    → internal user_id
//   3. lookup `sessions` by user_id; auto-renew if missing
//      or expiring soon (TTL 7d, renewal margin 2d)         → session_key
//   4. lookup `accounts` by user_id                         → business profile
//   5. persist everything to flutter_secure_storage
//   6. hydrate Riverpod AuthState
//
// On restart, tryRestoreSession() recovers the provider session, then
// self-heals the session_key against the DB so a stale local token
// realigns without forcing the user to log out and back in.
//
// NOTE (public extract): table names are generic (`profiles`, `sessions`,
// `accounts`) and the domain models are plain Maps. The production app
// uses strongly-typed freezed models.
// ============================================================

import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:logger/logger.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'error_mapper.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

// TTL applied when we create/renew a session_key.
const _newTokenTtl = Duration(days: 7);
// If the token expires within this margin, renew it.
const _renewalMargin = Duration(days: 2);

class _Keys {
  static const authUserId = 'auth_user_id';
  static const userId = 'user_id';
  static const sessionKey = 'session_key';
  static const jwt = 'jwt';
  static const account = 'account';
  static const profile = 'profile';

  /// Full provider session blob, needed so `currentUser` is populated after a
  /// cold start — without it `auth.uid()` is null in RLS and every read
  /// returns [].
  static const providerSession = 'provider_session';
}

// ── Auth State ───────────────────────────────────────────────

enum AuthStatus { unknown, authenticated, unauthenticated }

class AuthState {
  const AuthState({
    this.status = AuthStatus.unknown,
    this.authUserId,
    this.userId,
    this.sessionKey,
    this.jwt,
    this.profile,
    this.account,
    this.isLoading = false,
    this.errorMessage,
  });

  final AuthStatus status;
  final String? authUserId;
  final String? userId;
  final String? sessionKey;
  final String? jwt;
  final Map<String, dynamic>? profile;
  final Map<String, dynamic>? account;
  final bool isLoading;
  final String? errorMessage;

  bool get isAuthenticated => status == AuthStatus.authenticated;

  AuthState copyWith({
    AuthStatus? status,
    String? authUserId,
    String? userId,
    String? sessionKey,
    String? jwt,
    Map<String, dynamic>? profile,
    Map<String, dynamic>? account,
    bool? isLoading,
    String? errorMessage,
  }) {
    return AuthState(
      status: status ?? this.status,
      authUserId: authUserId ?? this.authUserId,
      userId: userId ?? this.userId,
      sessionKey: sessionKey ?? this.sessionKey,
      jwt: jwt ?? this.jwt,
      profile: profile ?? this.profile,
      account: account ?? this.account,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
    );
  }
}

// ── Auth Notifier ────────────────────────────────────────────

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState());

  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  SupabaseClient get _supabase => Supabase.instance.client;

  // ── Login ──────────────────────────────────────────────────

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      // 1. Provider auth
      final authResponse = await _supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );
      final authUser = authResponse.user;
      final session = authResponse.session;
      final jwt = session?.accessToken;
      if (authUser == null || session == null || jwt == null) {
        throw Exception('invalid login credentials');
      }

      // Persist the full provider session so it can be recovered on the next
      // cold start; without it the JWT is lost on restart and RLS denies reads.
      await _storage.write(
        key: _Keys.providerSession,
        value: jsonEncode(session.toJson()),
      );

      // 2. Lookup profile by auth_user_id → internal user_id
      final profileRows = await _supabase
          .from('profiles')
          .select()
          .eq('auth_user_id', authUser.id)
          .limit(1);
      if (profileRows.isEmpty) {
        throw Exception('user not found in profiles');
      }
      final profile = Map<String, dynamic>.from(profileRows.first);
      final internalUserId =
          (profile['user_id'] ?? profile['id']).toString();

      // 3. Resolve session_key (auto-renew if missing or expiring soon)
      final sessionToken = await _ensureFreshSessionToken(internalUserId);

      // 4. Lookup business account by user_id
      final accountRows = await _supabase
          .from('accounts')
          .select()
          .eq('user_id', internalUserId)
          .limit(1);
      final account = accountRows.isNotEmpty
          ? Map<String, dynamic>.from(accountRows.first)
          : null;

      // 5. Persist to secure storage
      await _persistSession(
        authUserId: authUser.id,
        userId: internalUserId,
        sessionKey: sessionToken,
        jwt: jwt,
        profile: profile,
        account: account,
      );

      // 6. Update state
      state = AuthState(
        status: AuthStatus.authenticated,
        authUserId: authUser.id,
        userId: internalUserId,
        sessionKey: sessionToken,
        jwt: jwt,
        profile: profile,
        account: account,
      );
      return true;
    } catch (e, st) {
      _log.e('Login failed', error: e, stackTrace: st);
      // User-facing es-ES message — never leak a stack trace or English error.
      state = state.copyWith(
        isLoading: false,
        status: AuthStatus.unauthenticated,
        errorMessage: ErrorMapper.map(e),
      );
      return false;
    }
  }

  // ── Restore session (called at app start) ──────────────────

  Future<bool> tryRestoreSession() async {
    try {
      // Recover the provider session FIRST — otherwise currentUser is null
      // after restart and RLS denies every read. recoverSession also refreshes
      // the JWT if it is close to expiring.
      final providerRaw = await _storage.read(key: _Keys.providerSession);
      if (providerRaw != null && providerRaw.isNotEmpty) {
        try {
          await _supabase.auth.recoverSession(providerRaw);
          final refreshed = _supabase.auth.currentSession;
          if (refreshed != null) {
            await _storage.write(
              key: _Keys.providerSession,
              value: jsonEncode(refreshed.toJson()),
            );
          }
        } catch (e) {
          _log.w('recoverSession failed: $e');
          await _storage.delete(key: _Keys.providerSession);
          state = const AuthState(status: AuthStatus.unauthenticated);
          return false;
        }
      }

      final storedSessionKey = await _storage.read(key: _Keys.sessionKey);
      final storedUserId = await _storage.read(key: _Keys.userId);
      final storedAuthUserId = await _storage.read(key: _Keys.authUserId);
      final storedJwt = await _storage.read(key: _Keys.jwt);
      final storedProfileJson = await _storage.read(key: _Keys.profile);
      final storedAccountJson = await _storage.read(key: _Keys.account);

      if (storedSessionKey == null || storedUserId == null) {
        state = const AuthState(status: AuthStatus.unauthenticated);
        return false;
      }

      // Self-healing: if the provider session is alive, refresh the session_key
      // against the DB. This closes the gap between local storage and the
      // `sessions` table (ghost token, app reinstalled elsewhere, DB restored…)
      // by rotating the token so both sides realign — no forced re-login.
      String activeSessionKey = storedSessionKey;
      String? activeJwt = storedJwt;
      if (_supabase.auth.currentSession != null) {
        try {
          final freshToken = await _ensureFreshSessionToken(storedUserId);
          if (freshToken != storedSessionKey) {
            await _storage.write(key: _Keys.sessionKey, value: freshToken);
            activeSessionKey = freshToken;
            _log.i('Restore: session_key rotated against DB');
          }
          final jwtNow = _supabase.auth.currentSession?.accessToken;
          if (jwtNow != null && jwtNow != storedJwt) {
            await _storage.write(key: _Keys.jwt, value: jwtNow);
            activeJwt = jwtNow;
          }
        } catch (e) {
          // Don't kill the session: keep the stored token and let the next
          // write surface the problem visibly.
          _log.w('Token refresh on restore failed (using stored token): $e');
        }
      }

      state = AuthState(
        status: AuthStatus.authenticated,
        authUserId: storedAuthUserId,
        userId: storedUserId,
        sessionKey: activeSessionKey,
        jwt: activeJwt,
        profile: storedProfileJson != null
            ? jsonDecode(storedProfileJson) as Map<String, dynamic>
            : null,
        account: storedAccountJson != null
            ? jsonDecode(storedAccountJson) as Map<String, dynamic>
            : null,
      );
      return true;
    } catch (e) {
      _log.e('Session restore failed', error: e);
      state = const AuthState(status: AuthStatus.unauthenticated);
      return false;
    }
  }

  // ── Logout ─────────────────────────────────────────────────

  Future<void> logout() async {
    try {
      await _supabase.auth.signOut();
    } catch (_) {
      // Silent — we're logging out regardless.
    }
    await _storage.deleteAll();
    state = const AuthState(status: AuthStatus.unauthenticated);
  }

  // ── Helpers ────────────────────────────────────────────────

  /// Returns a valid `session_key` for the write backend. If the row is
  /// missing or expires within the renewal margin, UPSERTs a new token with a
  /// fresh TTL. This is a direct write to an AUTH table (not a business table),
  /// which is the one documented exception to "writes only via the backend".
  Future<String> _ensureFreshSessionToken(String userId) async {
    final rows = await _supabase
        .from('sessions')
        .select()
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .limit(1);

    final now = DateTime.now().toUtc();
    final renewalThreshold = now.add(_renewalMargin);

    Map<String, dynamic>? existing =
        rows.isNotEmpty ? Map<String, dynamic>.from(rows.first) : null;

    final existingToken = existing?['token'] as String?;
    final existingExpiry = existing?['expires_at'] != null
        ? DateTime.tryParse(existing!['expires_at'].toString())?.toUtc()
        : null;

    final needsRenewal = existing == null ||
        existingToken == null ||
        existingToken.isEmpty ||
        existingExpiry == null ||
        existingExpiry.isBefore(renewalThreshold);

    if (!needsRenewal) {
      return existingToken;
    }

    final newToken = _generateSessionToken(userId);
    final newExpiry = now.add(_newTokenTtl).toIso8601String();

    // Upsert on UNIQUE(user_id). Chain `.select('id')` to fail fast: if RLS
    // silently blocked the write, the result would be empty and we throw
    // instead of returning a token the DB does not actually know about.
    final affected = await _supabase
        .from('sessions')
        .upsert(
          {'user_id': userId, 'token': newToken, 'expires_at': newExpiry},
          onConflict: 'user_id',
        )
        .select('id');

    if (affected.isEmpty) {
      throw StateError(
        'Could not renew session: upsert on `sessions` returned no row. '
        'Check RLS policies and UNIQUE(user_id).',
      );
    }

    _log.i('Session token renewed (ttl 7d)');
    return newToken;
  }

  String _generateSessionToken(String userId) {
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    final rand = Random.secure();
    const chars =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final suffix =
        List.generate(8, (_) => chars[rand.nextInt(chars.length)]).join();
    return 'token_${userId}_${ts}_$suffix';
  }

  Future<void> _persistSession({
    required String authUserId,
    required String userId,
    required String sessionKey,
    required String jwt,
    required Map<String, dynamic> profile,
    Map<String, dynamic>? account,
  }) async {
    await _storage.write(key: _Keys.authUserId, value: authUserId);
    await _storage.write(key: _Keys.userId, value: userId);
    await _storage.write(key: _Keys.sessionKey, value: sessionKey);
    await _storage.write(key: _Keys.jwt, value: jwt);
    await _storage.write(key: _Keys.profile, value: jsonEncode(profile));
    if (account != null) {
      await _storage.write(key: _Keys.account, value: jsonEncode(account));
    }
  }
}

// ── Riverpod Provider ──────────────────────────────────────

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});
