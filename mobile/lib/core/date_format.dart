/// Date display. SPEC.md §8.3: `12 Mar 2027`, never `12/03/27`.
///
/// One format in all three languages, deliberately. `12/03/27` is 12 March to a
/// Malaysian reader and 3 December to an American one, and an order that waits
/// twelve months for a house handover is exactly where that ambiguity turns
/// into a missed measurement. The month is always a word.
library;

const List<String> _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// Formats a date as `12 Mar 2027`.
String formatDate(DateTime date) =>
    '${date.day} ${_months[date.month - 1]} ${date.year}';

/// Formats an instant as `12 Mar 2027 14:05`, in the reader's own zone.
///
/// Stored timestamps are UTC (SPEC.md 7) and displayed Asia/Kuala_Lumpur, which
/// on these handsets is simply local time. Converting on display rather than on
/// storage is what stops a quote taken at 11pm on the last day of a promo from
/// becoming the next day in transit.
String formatDateTime(DateTime instant) {
  final local = instant.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '${formatDate(local)} $hour:$minute';
}
