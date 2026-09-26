/// Where a visit is, and when the house can be measured. SPEC.md §13 C10.
///
/// Optional everywhere it is asked for: a deposit is never held up for an
/// address (hard rule 9). Captured at the fair when the customer has it, and
/// filled in later when they WhatsApp it — the office groups a day's visits
/// by postcode, so one drive covers every house in the area.
library;

/// A Malaysian postcode: exactly five digits. Mirrors the server's
/// `POSTCODE_PATTERN`, which refuses anything else.
final _postcode = RegExp(r'^\d{5}$');

/// The postcode as typed, trimmed; null when blank. Throws nothing — call
/// [postcodeIsValid] first.
String? cleanPostcode(String? typed) {
  final trimmed = typed?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// Blank is fine (not known yet); anything else must be five digits.
bool postcodeIsValid(String? typed) {
  final cleaned = cleanPostcode(typed);
  return cleaned == null || _postcode.hasMatch(cleaned);
}

/// Free text trimmed to null, the way every optional text field here is.
String? cleanText(String? typed) {
  final trimmed = typed?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}
