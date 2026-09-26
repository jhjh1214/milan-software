/// The server's live price edit, as far as a handset needs to know it.
library;

/// Mirrors `MIN_REASON_LENGTH` in backend/app/pricing/rate_edit.py: short
/// enough to type at a fair table, long enough to mean something in review.
/// The server is the authority; this only lets the sheet answer instantly.
const minPriceEditReasonLength = 4;
