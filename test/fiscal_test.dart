// Unit tests for the fiscal module.
// These mirror the kind of coverage the production app keeps green:
// rounding edge cases, VAT/withholding amounts, and Spanish ID validation.

import 'package:flutter_test/flutter_test.dart';
import 'package:field_app/core/utils/fiscal.dart';

void main() {
  group('Fiscal.redondear2 — banker\'s rounding to 2 decimals', () {
    test('rounds half to even', () {
      expect(Fiscal.redondear2(1.005), closeTo(1.0, 1e-9));
      expect(Fiscal.redondear2(2.675), closeTo(2.68, 1e-9));
    });

    test('keeps already-rounded values', () {
      expect(Fiscal.redondear2(10.0), 10.0);
      expect(Fiscal.redondear2(0.0), 0.0);
    });

    test('handles negatives', () {
      expect(Fiscal.redondear2(-1.235), closeTo(-1.24, 1e-9));
    });
  });

  group('Fiscal.calcularIVA / calcularIRPF', () {
    test('21% VAT on a round base', () {
      expect(Fiscal.calcularIVA(100, Fiscal.ivaGeneral), 21.0);
    });

    test('10% reduced VAT', () {
      expect(Fiscal.calcularIVA(250, Fiscal.ivaReducido), 25.0);
    });

    test('15% withholding', () {
      expect(Fiscal.calcularIRPF(100, Fiscal.irpfGeneral), 15.0);
    });

    test('total = subtotal + VAT - withholding', () {
      // 1000 + 210 - 150 = 1060
      expect(
        Fiscal.calcularTotal(1000,
            ivaPct: Fiscal.ivaGeneral, irpfPct: Fiscal.irpfGeneral),
        1060.0,
      );
    });
  });

  group('Fiscal.validarIVAHomogeneo — fail-closed mixed VAT guard', () {
    test('empty list is allowed', () {
      expect(Fiscal.validarIVAHomogeneo([]), isTrue);
    });
    test('uniform rates pass', () {
      expect(Fiscal.validarIVAHomogeneo([21, 21, 21]), isTrue);
    });
    test('mixed rates are blocked', () {
      expect(Fiscal.validarIVAHomogeneo([21, 10, 21]), isFalse);
    });
  });

  group('Fiscal.validarNIF — control-letter algorithm', () {
    test('valid DNI', () {
      expect(Fiscal.validarNIF('12345678Z'), isTrue);
    });
    test('DNI with wrong control letter', () {
      expect(Fiscal.validarNIF('12345678A'), isFalse);
    });
    test('valid CIF', () {
      expect(Fiscal.validarNIF('B12345674'), isTrue);
    });
    test('valid NIE (X0000000T)', () {
      expect(Fiscal.validarNIF('X0000000T'), isTrue);
    });
    test('empty / garbage', () {
      expect(Fiscal.validarNIF(''), isFalse);
      expect(Fiscal.validarNIF('NOT_AN_ID'), isFalse);
    });
    test('normalizes spaces, hyphens and case', () {
      expect(Fiscal.validarNIF(' 12345678-z '), isTrue);
    });
  });

  group('Fiscal.formatCurrency — es-ES style', () {
    test('thousands separator and decimal comma', () {
      expect(Fiscal.formatCurrency(1234.56), '1.234,56 €');
    });
    test('negative', () {
      expect(Fiscal.formatCurrency(-7.5), '-7,50 €');
    });
  });
}
