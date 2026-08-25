// =============================================================================
// SHE V3 — Validators
// =============================================================================
// V3-ERROR-CODES §3.
// =============================================================================

class Validators {
  static String? validateEmail(String? v) {
    if (v == null || v.isEmpty) return 'Email required';
    if (!RegExp(r'^[\w.+-]+@[\w-]+\.[\w.-]+$').hasMatch(v)) return 'Invalid email';
    return null;
  }

  /// V3-ERROR-CODES §3 — VALIDATION_PASSWORD_WEAK:
  /// min 12 chars, 1 upper, 1 lower, 1 digit, 1 special
  static String? validatePassword(String? v) {
    if (v == null || v.isEmpty) return 'Password required';
    if (v.length < 12) return 'Min 12 characters';
    if (!RegExp(r'[A-Z]').hasMatch(v)) return 'Must contain 1 uppercase';
    if (!RegExp(r'[a-z]').hasMatch(v)) return 'Must contain 1 lowercase';
    if (!RegExp(r'\d').hasMatch(v)) return 'Must contain 1 digit';
    if (!RegExp(r'[^A-Za-z0-9]').hasMatch(v)) return 'Must contain 1 special char';
    return null;
  }

  /// V3-ERROR-CODES §3 — VALIDATION_PHONE_INVALID:
  /// Ethiopian: ^(\+251|0)?9\d{8}$
  static String? validatePhone(String? v) {
    if (v == null || v.isEmpty) return null;   // phone optional
    if (!RegExp(r'^(\+251|0)?9\d{8}$').hasMatch(v)) {
      return 'Ethiopian format: +2519XXXXXXXX or 09XXXXXXXX';
    }
    return null;
  }
}
