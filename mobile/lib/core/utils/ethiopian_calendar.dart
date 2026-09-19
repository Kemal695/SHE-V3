// =============================================================================
// SHE V3 — Ethiopian Calendar utility
// =============================================================================
// V3-I18N §7. 13 months × 30 days + Pagume (5/6 days). 7-8 years behind Gregorian.
// New year: September 11 (or 12 in leap year).
// =============================================================================

class EthiopianCalendar {
  static const List<String> monthNames = [
    'Meskerem', 'Tikimt', 'Hidar', 'Tahsas', 'Tir', 'Yekatit',
    'Megabit', 'Miazia', 'Ginbot', 'Sene', 'Hamle', 'Nehase', 'Pagume'
  ];

  static const List<String> monthNamesAm = [
    'መስከረም', 'ጥቅምት', 'ኅዳር', 'ታኅሣሥ', 'ጥር', 'የካቲት',
    'መጋቢት', 'ሚያዝያ', 'ግንቦት', 'ሰኔ', 'ሐምሌ', 'ነሐሴ', 'ጳጉሜ'
  ];

  /// Convert Gregorian DateTime to Ethiopian calendar date.
  /// Returns (year, month 1-13, day 1-30).
  static (int year, int month, int day) gregorianToEthiopian(DateTime gregorian) {
    // Algorithm: JD-based conversion
    final jd = _toJulianDay(gregorian);
    final ethiopian = _julianDayToEthiopian(jd);
    return ethiopian;
  }

  /// Format Ethiopian date as DD/MM/YYYY with optional era suffix.
  static String format(DateTime gregorian, {String locale = 'en'}) {
    final (year, month, day) = gregorianToEthiopian(gregorian);
    final names = locale == 'am' ? monthNamesAm : monthNames;
    final monthName = month <= 13 ? names[month - 1] : '';

    if (locale == 'am') {
      return '$day $monthName $year እ.ኤ.አ.';
    }
    return '$day $monthName $year';
  }

  /// Format as DD/MM/YYYY (numeric).
  static String formatNumeric(DateTime gregorian) {
    final (year, month, day) = gregorianToEthiopian(gregorian);
    return '${day.toString().padLeft(2, '0')}/${month.toString().padLeft(2, '0')}/$year';
  }

  // Julian Day Number calculation
  static int _toJulianDay(DateTime date) {
    int a = (14 - date.month) ~/ 12;
    int y = date.year + 4800 - a;
    int m = date.month + 12 * a - 3;
    return date.day + (153 * m + 2) ~/ 5 + 365 * y + y ~/ 4 - y ~/ 100 + y ~/ 400 - 32045;
  }

  static (int, int, int) _julianDayToEthiopian(int jd) {
    // Ethiopian epoch: JD 1724221.5 (Meskerem 1, 1 EC = Aug 29, 8 CE)
    const ethiopianEpoch = 1723856;
    final r = (jd - ethiopianEpoch) % 1461;
    final n = (r % 365) + 365 * (r ~/ 365);

    final year = (jd - ethiopianEpoch) ~/ 1461 * 4 + r ~/ 365 - r ~/ 1461;
    final month = n ~/ 30 + 1;
    final day = n % 30 + 1;

    return (year, month, day);
  }
}
