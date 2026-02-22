import 'dart:math';

/// Generate a unique ID using microsecond timestamp + random suffix.
/// Format: `<microsecondsSinceEpoch>_<6-digit-random>`
/// Collision probability is negligible: same-microsecond calls
/// would need matching random numbers (1 in 1,000,000).
String generateUniqueId() {
  final now = DateTime.now();
  final random = Random();
  return '${now.microsecondsSinceEpoch}_${random.nextInt(999999).toString().padLeft(6, '0')}';
}
