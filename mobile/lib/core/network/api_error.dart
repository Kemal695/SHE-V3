// =============================================================================
// SHE V3 — API error message extraction
// =============================================================================
// The backend returns errors shaped as:
//   {"error":{"code":"...","http_status":422,"message":"...","request_id":"..."}}
//
// Showing a raw DioException to the user is useless — they see
// "DioException [bad response]: This request was invalid..." instead of the
// actual reason. This pulls out the server's human-readable `message`, which is
// what validation failures (e.g. an invalid cron) rely on to be actionable.
// =============================================================================

import 'package:dio/dio.dart';

/// The server's machine-readable error code, e.g. `AUTH_MFA_REQUIRED`.
///
/// Needed because [DioException.toString] contains the status code but **not**
/// the response body, so `e.toString().contains('AUTH_MFA_REQUIRED')` is always
/// false. Branching on the code (not the message, not the status) is the only
/// reliable way to tell "wrong password" from "password fine, code needed" —
/// both are HTTP 401.
String? apiErrorCode(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map) {
      final err = data['error'];
      if (err is Map) {
        final code = err['code'];
        if (code is String && code.isNotEmpty) return code;
      }
      final code = data['code'];
      if (code is String && code.isNotEmpty) return code;
    }
  }
  return null;
}

/// Best-effort human-readable message for [error].
///
/// Falls back to `toString()` when the body isn't the expected shape, so this is
/// always safe to call.
String apiErrorMessage(Object error) {
  if (error is DioException) {
    final data = error.response?.data;

    if (data is Map) {
      // Preferred: {"error": {"message": "..."}}
      final err = data['error'];
      if (err is Map) {
        final msg = err['message'];
        if (msg is String && msg.isNotEmpty) return msg;
      }
      // Fallback: {"message": "..."}
      final msg = data['message'];
      if (msg is String && msg.isNotEmpty) return msg;
    }

    // No body (network failure, timeout) — say something meaningful.
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The server took too long to respond. Check that the backend is running and reachable.';
      case DioExceptionType.connectionError:
        return 'Could not reach the server. Check your Wi-Fi and that the backend is running.';
      case DioExceptionType.badResponse:
        return 'Server returned ${error.response?.statusCode ?? 'an error'}.';
      default:
        return error.message ?? error.toString();
    }
  }
  return error.toString();
}
