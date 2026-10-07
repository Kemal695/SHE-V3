// =============================================================================
// SHE V3 — ETB currency formatter
// =============================================================================
// V3-I18N §3.10.
// Amharic: "1,234.56 ብር" (ብር symbol)
// English: "1,234.56 ETB"
// Format: comma thousands separator, dot decimal.
// =============================================================================

class EtbFormatter {
  /// Domestic tariff used when the backend does not supply a cost.
  ///
  /// The per-node Energy screen reads `total_cost_etb` straight from the API and
  /// never needs this. The home-level aggregate (home_energy_screen.dart) DOES
  /// need it, because `/homes/{id}/energy/summary` is still a Phase 4 stub that
  /// returns no numbers at all. ~11.5 ETB/kWh is the mid-tier EEU residential
  /// rate; it is a *display* estimate, not a billing figure, and is labelled as
  /// such in the UI.
  static const double defaultTariffEtbPerKwh = 11.5;

  /// Estimated cost of [kwh] at [tariff] (defaults to the domestic rate).
  static double kwhToEtb(double kwh,
          {double tariff = defaultTariffEtbPerKwh}) =>
      kwh * tariff;

  /// Format an amount in ETB with locale-aware symbol.
  static String format(double amount, String locale) {
    final formatted = _formatNumber(amount);
    return locale == 'am' ? '$formatted ብር' : '$formatted ETB';
  }

  /// Format just the number (no symbol) — for tables/charts.
  static String formatNumber(double amount) {
    return _formatNumber(amount);
  }

  static String _formatNumber(double amount) {
    // Round to 2 decimal places
    final parts = amount.toStringAsFixed(2).split('.');

    // Add thousands separators to integer part
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (m) => '${m[1]},',
    );

    // For amounts < 1 ETB, round to nearest birr (no cents)
    if (amount < 1 && amount > 0) {
      return '1';
    }

    return '$intPart.${parts[1]}';
  }
}
