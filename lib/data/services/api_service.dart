// ============================================================
// API Service — HTTP client for the automation/write backend
// ============================================================
//
// All business writes flow through here. The client has no backend of
// its own: it talks to a webhook-style automation backend that only
// understands an internal `session_key` — never the provider JWT.
//
// • baseUrl  = AppConfig.apiBaseUrl
// • Interceptor injects `session_key` (as both `token` and `session_key`
//   for backend-contract compatibility) into every POST body / form.
// • Default timeout 30 s; 90 s for slow, document-generating endpoints.
// • dio_smart_retry: up to 2 retries with backoff on 5xx / timeout.
// • Errors are mapped to human es-ES messages via ErrorMapper.
// ============================================================

import 'package:dio/dio.dart';
import 'package:dio_smart_retry/dio_smart_retry.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';

import '../../core/config/app_config.dart';
import 'auth_service.dart';
import 'error_mapper.dart';
import 'toast_service.dart';

final _log = Logger(printer: PrettyPrinter(methodCount: 0));

/// Slow endpoints that get a 90 s timeout instead of 30 s — anything that
/// triggers server-side document generation (PDF build, OCR scan, AI chat).
const _slowEndpoints = [
  '/quotes/create',
  '/quotes/action',
  '/invoices/create',
  '/invoices/action',
  '/invoices/from-quote',
  '/invoices/scan',
  '/invoices/chat',
];

/// Wraps Dio with session-key injection, timeouts and retry.
class ApiService {
  ApiService({required String sessionKey}) : _sessionKey = sessionKey {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: AppConfig.connectTimeout,
      receiveTimeout: AppConfig.defaultTimeout,
      sendTimeout: AppConfig.defaultTimeout,
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
    ));

    // ── Session-key interceptor ──────────────────────────────
    //
    // The session_key is injected under BOTH `token` and `session_key`
    // because different backend routes historically expect different field
    // names. Sending both is harmless (each route ignores the one it does
    // not read) and removed a whole class of "write silently dropped" bugs.
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.method == 'POST' && options.data is Map) {
          final data = options.data as Map<String, dynamic>;
          data['token'] = _sessionKey;
          data['session_key'] = _sessionKey;
        } else if (options.method == 'POST' && options.data == null) {
          options.data = {
            'token': _sessionKey,
            'session_key': _sessionKey,
          };
        }

        // Per-endpoint timeout override for slow routes.
        for (final ep in _slowEndpoints) {
          if (options.path.contains(ep)) {
            options.receiveTimeout = AppConfig.slowTimeout;
            options.sendTimeout = AppConfig.slowTimeout;
            break;
          }
        }

        handler.next(options);
      },
    ));

    // ── Smart retry: up to 2 retries on 5xx / timeout ─────────
    _dio.interceptors.add(RetryInterceptor(
      dio: _dio,
      logPrint: (msg) => _log.d(msg),
      retries: 2,
      retryDelays: const [
        Duration(seconds: 1),
        Duration(seconds: 3),
      ],
      retryableExtraStatuses: {408}, // Request Timeout
    ));
  }

  late final Dio _dio;
  final String _sessionKey;

  String get sessionKey => _sessionKey;

  // ── Generic POST (most write webhooks are POST) ────────────

  /// POST to [path] with [body]. The interceptor adds the session key.
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await _dio.post<dynamic>(
        path,
        data: body ?? {},
        cancelToken: cancelToken,
      );
      return _unwrap(response.data);
    } on DioException catch (e) {
      final message = ErrorMapper.map(e.message ?? e.toString());
      _log.e('API error on $path', error: e);
      ToastService.error(message);
      rethrow;
    }
  }

  /// GET for read endpoints that expect `user_id` + `session_key` as query
  /// params. The `_t` cache-buster avoids stale intermediary caches.
  Future<Map<String, dynamic>> get(
    String path, {
    required String userId,
    Map<String, String>? queryParams,
    CancelToken? cancelToken,
  }) async {
    try {
      final params = <String, dynamic>{
        'user_id': userId,
        'session_key': _sessionKey,
        '_t': DateTime.now().millisecondsSinceEpoch.toString(),
        ...?queryParams,
      };
      final response = await _dio.get<dynamic>(
        path,
        queryParameters: params,
        cancelToken: cancelToken,
      );
      return _unwrap(response.data);
    } on DioException catch (e) {
      final message = ErrorMapper.map(e.message ?? e.toString());
      _log.e('API error on $path', error: e);
      ToastService.error(message);
      rethrow;
    }
  }

  /// Multipart upload (e.g. scan an invoice image). The session key is added
  /// as a form field because the interceptor only mutates JSON Map bodies.
  Future<Map<String, dynamic>> upload(
    String path, {
    required String filePath,
    required String fieldName,
    Map<String, dynamic>? extraFields,
    CancelToken? cancelToken,
  }) async {
    try {
      final formData = FormData.fromMap({
        'token': _sessionKey,
        'session_key': _sessionKey,
        fieldName: await MultipartFile.fromFile(filePath),
        ...?extraFields,
      });
      final response = await _dio.post<dynamic>(
        path,
        data: formData,
        cancelToken: cancelToken,
      );
      return _unwrap(response.data);
    } on DioException catch (e) {
      final message = ErrorMapper.map(e.message ?? e.toString());
      _log.e('Upload error on $path', error: e);
      ToastService.error(message);
      rethrow;
    }
  }

  /// The backend may return a single object or wrap it in a one-element list.
  Map<String, dynamic> _unwrap(dynamic data) {
    if (data is List && data.isNotEmpty) {
      return Map<String, dynamic>.from(data.first as Map);
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }
    return {'data': data};
  }

  void dispose() {
    _dio.close(force: true);
  }
}

// ── Riverpod Provider ──────────────────────────────────────────

/// ApiService wired to the AuthState `session_key`. It rebuilds automatically
/// when the auto-renew rotates the token.
///
/// IMPORTANT: repositories that depend on this should `ref.watch` (not
/// `ref.read`) so they pick up the new client after a token renewal.
final apiServiceProvider = Provider<ApiService>((ref) {
  final auth = ref.watch(authProvider);
  final sessionKey = auth.sessionKey;
  if (sessionKey == null || sessionKey.isEmpty) {
    throw StateError('apiServiceProvider: no session_key (user not authenticated).');
  }
  final api = ApiService(sessionKey: sessionKey);
  ref.onDispose(api.dispose);
  return api;
});
