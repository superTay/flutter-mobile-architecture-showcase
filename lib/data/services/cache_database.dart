// ============================================================
// Offline Cache — raw SQLite via drift (no codegen)
// ============================================================
//
// Uses drift's low-level API with raw SQL — no drift_dev code generation
// (avoids an `analyzer` version conflict with the Riverpod generator).
//
// Strategy: stale-while-revalidate. When connectivity drops, repositories
// read from this cache and the UI disables write actions instead of failing.
// ============================================================

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Lightweight offline cache using raw SQL (no codegen).
class CacheDatabase {
  CacheDatabase._();

  static CacheDatabase? _instance;
  static CacheDatabase get instance => _instance ??= CacheDatabase._();

  late final GeneratedDatabase _db;
  bool _initialized = false;

  /// Initialize the database. Call once at app start.
  Future<void> init() async {
    if (_initialized) return;

    final executor = driftDatabase(
      name: 'app_cache',
      web: DriftWebOptions(
        sqlite3Wasm: Uri.parse('sqlite3.wasm'),
        driftWorker: Uri.parse('drift_worker.js'),
        onResult: (result) {
          if (result.missingFeatures.isNotEmpty) {
            debugPrint('[CacheDB] Missing web features: ${result.missingFeatures}');
          }
        },
      ),
    );
    _db = _RawDatabase(executor);

    await _db.customStatement('''
      CREATE TABLE IF NOT EXISTS quotes_cache (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        json_data TEXT NOT NULL,
        cached_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    ''');
    await _db.customStatement('''
      CREATE TABLE IF NOT EXISTS invoices_cache (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'issued',
        json_data TEXT NOT NULL,
        cached_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    ''');
    await _db.customStatement('''
      CREATE TABLE IF NOT EXISTS account_cache (
        id TEXT PRIMARY KEY,
        user_id TEXT NOT NULL,
        json_data TEXT NOT NULL,
        cached_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
      )
    ''');

    _initialized = true;
  }

  // ── Quotes cache ──────────────────────────────────────────

  Future<void> cacheQuotes(
    String userId,
    List<Map<String, dynamic>> quotes,
  ) async {
    for (final q in quotes) {
      await _db.customStatement(
        'INSERT OR REPLACE INTO quotes_cache (id, user_id, json_data, cached_at) '
        'VALUES (?, ?, ?, strftime(\'%s\',\'now\'))',
        [q['id'], userId, jsonEncode(q)],
      );
    }
  }

  Future<List<Map<String, dynamic>>> getCachedQuotes(String userId) async {
    final rows = await _db.customSelect(
      'SELECT json_data FROM quotes_cache WHERE user_id = ? ORDER BY cached_at DESC',
      variables: [Variable.withString(userId)],
    ).get();
    return rows
        .map((r) => jsonDecode(r.read<String>('json_data')) as Map<String, dynamic>)
        .toList();
  }

  // ── Invoices cache ────────────────────────────────────────

  Future<void> cacheInvoices(
    String userId,
    List<Map<String, dynamic>> invoices,
  ) async {
    for (final inv in invoices) {
      await _db.customStatement(
        'INSERT OR REPLACE INTO invoices_cache (id, user_id, kind, json_data, cached_at) '
        'VALUES (?, ?, ?, ?, strftime(\'%s\',\'now\'))',
        [inv['id'], userId, inv['kind'] ?? 'issued', jsonEncode(inv)],
      );
    }
  }

  Future<List<Map<String, dynamic>>> getCachedInvoices(
    String userId, {
    String? kind,
  }) async {
    String sql = 'SELECT json_data FROM invoices_cache WHERE user_id = ?';
    final vars = <Variable>[Variable.withString(userId)];
    if (kind != null) {
      sql += ' AND kind = ?';
      vars.add(Variable.withString(kind));
    }
    sql += ' ORDER BY cached_at DESC';

    final rows = await _db.customSelect(sql, variables: vars).get();
    return rows
        .map((r) => jsonDecode(r.read<String>('json_data')) as Map<String, dynamic>)
        .toList();
  }

  // ── Account cache ─────────────────────────────────────────

  Future<void> cacheAccount(
    String userId,
    Map<String, dynamic> account,
  ) async {
    await _db.customStatement(
      'INSERT OR REPLACE INTO account_cache (id, user_id, json_data, cached_at) '
      'VALUES (?, ?, ?, strftime(\'%s\',\'now\'))',
      [account['id'], userId, jsonEncode(account)],
    );
  }

  Future<Map<String, dynamic>?> getCachedAccount(String userId) async {
    final rows = await _db.customSelect(
      'SELECT json_data FROM account_cache WHERE user_id = ? LIMIT 1',
      variables: [Variable.withString(userId)],
    ).get();
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first.read<String>('json_data'))
        as Map<String, dynamic>;
  }

  // ── Clear all ─────────────────────────────────────────────

  Future<void> clearAll() async {
    await _db.customStatement('DELETE FROM quotes_cache');
    await _db.customStatement('DELETE FROM invoices_cache');
    await _db.customStatement('DELETE FROM account_cache');
  }
}

// ── Minimal GeneratedDatabase for drift raw SQL ─────────────

class _RawDatabase extends GeneratedDatabase {
  _RawDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, dynamic>> get allTables => [];

  @override
  Iterable<DatabaseSchemaEntity> get allSchemaEntities => [];
}

// ── Riverpod Provider ───────────────────────────────────────

final cacheDatabaseProvider = Provider<CacheDatabase>((ref) {
  return CacheDatabase.instance;
});
