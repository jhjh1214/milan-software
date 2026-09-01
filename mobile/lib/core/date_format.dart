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
