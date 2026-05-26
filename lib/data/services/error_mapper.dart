// ============================================================
// Error Mapper
// ============================================================
// Translates raw exceptions / network errors into short, human,
// es-ES messages safe to show the end user. We never surface an
// English stack trace or a raw "Network error" to a non-technical
// user working from a job site.
// ============================================================

class ErrorMapper {
  ErrorMapper._();

  /// Accepts either an exception object or a string and returns a
  /// user-facing message in Spanish.
  static String map(Object error) {
    final raw = error.toString().toLowerCase();

    if (raw.contains('invalid login credentials') ||
        raw.contains('invalid_credentials')) {
      return 'El correo o la contraseña no son correctos.';
    }
    if (raw.contains('timeout') || raw.contains('timed out')) {
      return 'La conexión está tardando demasiado. Inténtalo de nuevo.';
    }
    if (raw.contains('socketexception') ||
        raw.contains('failed host lookup') ||
        raw.contains('network')) {
      return 'Sin conexión. Comprueba tu internet e inténtalo de nuevo.';
    }
    if (raw.contains('user not found')) {
      return 'No encontramos tu cuenta. Contacta con soporte.';
    }

    // Generic, never leaks technical detail.
    return 'Algo no ha ido bien. Inténtalo de nuevo en un momento.';
  }
}
