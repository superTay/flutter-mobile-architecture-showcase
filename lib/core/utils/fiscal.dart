// ============================================================
// Fiscal Utilities — Spanish tax system
// ============================================================
// Exact financial math. Ported 1:1 from the web app's TypeScript
// implementation to guarantee cross-language parity: the same
// invoice must total to the same cent on web and mobile.
//
// NEVER change rounding or validation logic without mirroring the
// other platform. Always compute with `decimal`; convert to double
// only for presentation. Never do `(value * 100).round() / 100`
// inline in a widget.
// ============================================================

import 'package:decimal/decimal.dart';

/// Fiscal calculation utilities — Spanish tax system.
class Fiscal {
  Fiscal._();

  // ── IVA (VAT) rates ────────────────────────────────────────
  static const double ivaGeneral = 21.0;
  static const double ivaReducido = 10.0;
  static const double ivaIsp = 0.0; // Reverse charge (Inversión Sujeto Pasivo)

  // ── IRPF (withholding) rates ───────────────────────────────
  static const double irpfGeneral = 15.0;
  static const double irpfNuevos = 7.0; // First 3 years of activity

  /// Banker's rounding to 2 decimal places.
  /// Mirrors the web implementation's `redondear2(n)`.
  static double redondear2(double n) {
    final d = Decimal.parse(n.toStringAsFixed(10));
    final rounded = (d * Decimal.fromInt(100)).round() / Decimal.fromInt(100);
    return rounded.toDouble();
  }

  /// Calculate VAT amount from a subtotal.
  static double calcularIVA(double subtotal, double ivaPct) {
    return redondear2(subtotal * ivaPct / 100);
  }

  /// Calculate withholding (IRPF) amount from a subtotal.
  static double calcularIRPF(double subtotal, double irpfPct) {
    return redondear2(subtotal * irpfPct / 100);
  }

  /// Calculate total: subtotal + VAT - withholding.
  static double calcularTotal(
    double subtotal, {
    double ivaPct = ivaGeneral,
    double irpfPct = 0,
  }) {
    final iva = calcularIVA(subtotal, ivaPct);
    final irpf = calcularIRPF(subtotal, irpfPct);
    return redondear2(subtotal + iva - irpf);
  }

  /// Validate that all line items share the same VAT rate.
  /// Fail-closed: returns false if ANY item differs → block emission.
  ///
  /// Mixed VAT is not allowed on a single invoice. This guard exists for
  /// parity with the web app; whenever per-line VAT rates are introduced,
  /// call this before any emission and block the CTA if it returns false.
  static bool validarIVAHomogeneo(List<double> ivaRates) {
    if (ivaRates.isEmpty) return true;
    final first = ivaRates.first;
    return ivaRates.every((rate) => rate == first);
  }

  /// Validate Spanish NIF / CIF / NIE format with the control-letter
  /// algorithm. Normalizes whitespace, hyphens and case first.
  static bool validarNIF(String nif) {
    final cleaned = nif.replaceAll(RegExp(r'[\s\-]'), '').toUpperCase();
    if (cleaned.isEmpty) return false;

    // CIF: letter (A-W) + 7 digits + control
    final cifRegex = RegExp(r'^[A-W]\d{7}[A-J0-9]$');
    if (cifRegex.hasMatch(cleaned)) return true;

    // NIF (DNI): 8 digits + control letter
    final nifRegex = RegExp(r'^\d{8}[A-Z]$');
    if (nifRegex.hasMatch(cleaned)) {
      const letters = 'TRWAGMYFPDXBNJZSQVHLCKE';
      final number = int.tryParse(cleaned.substring(0, 8));
      if (number == null) return false;
      return cleaned[8] == letters[number % 23];
    }

    // NIE: X/Y/Z + 7 digits + control letter
    final nieRegex = RegExp(r'^[XYZ]\d{7}[A-Z]$');
    if (nieRegex.hasMatch(cleaned)) {
      String prefix;
      switch (cleaned[0]) {
        case 'X':
          prefix = '0';
        case 'Y':
          prefix = '1';
        case 'Z':
          prefix = '2';
        default:
          return false;
      }
      const letters = 'TRWAGMYFPDXBNJZSQVHLCKE';
      final number = int.tryParse('$prefix${cleaned.substring(1, 8)}');
      if (number == null) return false;
      return cleaned[8] == letters[number % 23];
    }

    return false;
  }

  /// Format currency in European style: 1.234,56 €
  static String formatCurrency(double amount) {
    final rounded = redondear2(amount);
    final parts = rounded.toStringAsFixed(2).split('.');
    final intPart = parts[0];
    final decPart = parts[1];

    final buffer = StringBuffer();
    final negative = intPart.startsWith('-');
    final digits = negative ? intPart.substring(1) : intPart;

    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) {
        buffer.write('.');
      }
      buffer.write(digits[i]);
    }

    return '${negative ? '-' : ''}${buffer.toString()},$decPart €';
  }
}
