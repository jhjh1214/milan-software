/// Which customer a rate lock belongs to. SPEC.md §6.1 and §13 B9.
///
/// > The lock is on **customer + category**, not on the order.
///
/// The point of a twelve-month hold is that the customer comes back — with a
/// *new quote*. So the key has to survive that, and it was not: it was the
/// quote id, which meant the hold could never match again. The customer paid
/// RM300 at the fair, returned in March, and was quoted the standard rate —
/// **more** than the hold they bought, after the app had told them the promo
/// rate was held until next August. No test covered a second quote, which is
/// why nothing caught it.
///
/// ## Why the phone
///
/// There is no `customers` table yet (§13 B9 is blocking) and a quote carries a
/// free-text name and phone. The phone is what the shop actually collects, and
/// keying on it errs in the direction the customer paid for: a returning
/// customer gets the hold they bought.
///
/// ## Why the normalisation is narrow
///
/// Merging two customers hands one of them the other's held prices, so this
/// does the least it can get away with: strip the punctuation people type,
/// accept a `+60` or `60` country prefix as a leading zero, and require at
/// least nine digits. Anything shorter is treated as **no phone at all** rather
/// than as a key — a fragment would collide with every other fragment.
///
/// With no usable phone the key falls back to the quote id. That is exactly the
/// old behaviour, so a walk-in who gives no number is no worse off, and their
/// key can never match somebody else's.
///
/// Pure: no clock, no I/O, no Flutter.
library;

/// The shortest string that can be a Malaysian phone number.
///
/// An `03` landline is nine digits including its zero; a mobile is ten or
/// eleven. Below nine is a fragment.
const int minPhoneDigits = 9;

/// Which customer a lock belongs to, and whether the phone gave it.
class CustomerKey {
  const CustomerKey(this.value, {required this.fromPhone});

  /// Prefixed so the two kinds can never collide: a quote id that happened to
  /// look like a phone number would otherwise be one.
  final String value;

  /// False when there was no usable phone and the quote id was used instead.
  /// A screen may want to say that the hold will not follow the customer.
  final bool fromPhone;

  @override
  bool operator ==(Object other) =>
      other is CustomerKey &&
      other.value == value &&
      other.fromPhone == fromPhone;

  @override
  int get hashCode => Object.hash(value, fromPhone);

  @override
  String toString() => value;
}

/// A phone reduced to digits, or null when what is left is not a phone.
///
/// Returns null rather than a best guess. A key built from four digits would
/// match every other four-digit fragment, and the cost of that is one customer
/// being given another's prices.
String? normalisePhone(String? raw) {
  if (raw == null) return null;

  final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return null;

  // `+60 12...` and `60 12...` are the same number as `012...`.
  //
  // A local number is safe from this without a second guard: `060...` starts
  // with `06`, not `60`, so it is never rewritten. An earlier version added
  // `&& !digits.startsWith('0')` to protect it, which reads as though it does
  // something and cannot — mutation testing found the clause was dead. The
  // case is still in the fixtures, because the property is worth pinning even
  // though it falls out of the prefix rather than out of a check.
  final local = digits.startsWith('60') ? '0${digits.substring(2)}' : digits;

  return local.length >= minPhoneDigits ? local : null;
}

/// The key a lock is stored and looked up under.
CustomerKey customerKeyFor({required String? phone, required String quoteId}) {
  final normalised = normalisePhone(phone);
  return normalised == null
      ? CustomerKey('quote:$quoteId', fromPhone: false)
      : CustomerKey('phone:$normalised', fromPhone: true);
}
