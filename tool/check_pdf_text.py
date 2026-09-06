"""Extracts the real text from a rendered quotation and checks what it says.

Why this exists as a separate tool rather than a Dart assertion: the PDF embeds
a subset TrueType font, so text is stored as glyph indices rather than
characters. Grepping the file for "Tax Invoice" would pass whether or not the
words were printed -- a test that cannot fail. Only a proper text extraction
proves the document says what we think it says.

CLAUDE.md hard rule 7 and SPEC.md section 10.1: nothing this system prints may
say "Tax Invoice" or "e-Invoice", or display a UIN or a validation QR. SQL
Account is the sole issuer of record, and two systems issuing for one sale
produces two validated UINs and a 72-hour cancellation problem.

Run `flutter test test/ui/quote_pdf_test.dart` first; it writes the samples to
mobile/build/test-pdfs/.

    python tool/check_pdf_text.py
"""
import pathlib
import re
import sys

from pypdf import PdfReader

ROOT = pathlib.Path(__file__).resolve().parent.parent
PDF_DIR = ROOT / "mobile" / "build" / "test-pdfs"

# This script prints Chinese. A Windows console defaults to cp1252, which
# cannot encode it, and the script died on its own progress output before it
# could report a single failure. CI is UTF-8 and never saw it.
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        stream.reconfigure(encoding="utf-8", errors="replace")

# Phrases no quotation may carry. Matched case-insensitively on extracted text.
FORBIDDEN = [
    "tax invoice",
    "e-invoice",
    "einvoice",
    "invois cukai",
    "税务发票",
    "电子发票",
]

# Each language must positively deny being a tax document.
DENIALS = {
    "zh": "不是税务发票",
    "en": "not a tax invoice",
    "ms": "bukan invois cukai",
}

# And each must carry the reference-price promise from SPEC.md section 8.5.
PROMISE = {
    "zh": "只会相同或更低",
    "en": "same or lower",
    "ms": "sama atau lebih rendah",
}

# The revised order document (SPEC.md section 11, Phase 6) is a different
# document with the same legal constraint, so it gets its own denial and its
# own promise. The denial differs in wording -- it denies being a tax invoice
# while calling itself a revised ORDER CONFIRMATION -- and the promise is the
# past-tense version: the quotation rounded up, this one did not.
REVISED_DENIALS = {
    "zh": "非税务发票",
    "en": "not a tax invoice",
    "ms": "bukan invois cukai",
}

REVISED_PROMISE = {
    "zh": "相同或更低",
    "en": "same or lower",
    "ms": "sama atau lebih rendah",
}


def extract(path: pathlib.Path) -> str:
    reader = PdfReader(path)
    return "\n".join(page.extract_text() or "" for page in reader.pages)


def main() -> int:
    if not PDF_DIR.exists():
        print(f"no sample PDFs at {PDF_DIR}", file=sys.stderr)
        print("run: cd mobile && flutter test test/ui/quote_pdf_test.dart", file=sys.stderr)
        return 1

    failures = []
    checked = 0

    for path in sorted(PDF_DIR.glob("quote-*.pdf")):
        lang = path.stem.split("-")[-1]
        # quote-long.pdf is the 30-line paging stress document. It carries the
        # same disclaimer but not the demo's specific figures, so it is checked
        # for the legal constraint only.
        is_demo = lang in DENIALS
        if not is_demo:
            lang = "zh"
        text = extract(path)
        flat = re.sub(r"\s+", "", text)
        lower = text.lower()
        checked += 1

        print(f"\n=== {path.name} ({len(text)} chars extracted) ===")

        for phrase in FORBIDDEN:
            # The denial sentence is allowed to name a tax invoice: saying "this
            # is NOT a tax invoice" is the point. Anything else is not.
            denial = DENIALS.get(lang, "")
            without_denial = lower.replace(denial.lower(), "")
            without_denial = re.sub(r"\s+", "", without_denial)
            if phrase in without_denial or phrase in without_denial.lower():
                failures.append(f"{path.name}: forbidden phrase {phrase!r}")

        if lang in DENIALS:
            want = re.sub(r"\s+", "", DENIALS[lang])
            if want not in flat:
                failures.append(f"{path.name}: missing denial {DENIALS[lang]!r}")
            else:
                print(f"  denial present: {DENIALS[lang]}")

        if lang in PROMISE:
            want = re.sub(r"\s+", "", PROMISE[lang])
            if want not in flat:
                failures.append(f"{path.name}: missing reference-price promise")
            else:
                print(f"  reference-price promise present: {PROMISE[lang]}")

        # The numbers the demo turns on: the curtain, the S-Track that adds on
        # top of it, and the blind that floors to the RM300 deposit.
        if is_demo:
            for want in ("552.00", "960.00", "162.00"):
                mark = "ok " if want in flat else "MISSING"
                print(f"  {mark} RM{want}")
                if want not in flat:
                    failures.append(f"{path.name}: expected RM{want} on the quote")

        if lang == "zh":
            # Proves the embedded CJK subset actually mapped: if the font were
            # missing, these would extract as tofu or vanish entirely.
            # 报价 is on every document; the room and product names only on the
            # demo one, whose rooms are 客厅 and 房间.
            wanted = ["报价"] + (["客厅", "夜帘"] if is_demo else ["房间"])
            for want in wanted:
                if want not in flat:
                    failures.append(
                        f"{path.name}: Chinese text {want!r} did not render"
                    )
            print(f"  Chinese glyphs extracted correctly ({', '.join(wanted)})")

    # The revised order document. Same legal constraint, and two things the
    # quotation does not have to prove: that BOTH numbers reached the page, and
    # that a window measured larger than quoted is named rather than buried in
    # the arithmetic.
    for path in sorted(PDF_DIR.glob("revised-*.pdf")):
        stem = path.stem
        lang = stem.split("-")[-1]
        is_over = "-over-" in stem
        # revised-pending.pdf is the unsynced-order document; it is English.
        if lang not in REVISED_DENIALS:
            lang = "en"
        text = extract(path)
        flat = re.sub(r"\s+", "", text)
        lower = text.lower()
        checked += 1

        print(f"\n=== {path.name} ({len(text)} chars extracted) ===")

        for phrase in FORBIDDEN:
            denial = REVISED_DENIALS.get(lang, "")
            without_denial = re.sub(
                r"\s+", "", lower.replace(denial.lower(), "")
            )
            if phrase in without_denial:
                failures.append(f"{path.name}: forbidden phrase {phrase!r}")

        want = re.sub(r"\s+", "", REVISED_DENIALS[lang])
        if want not in flat:
            failures.append(
                f"{path.name}: missing denial {REVISED_DENIALS[lang]!r}"
            )
        else:
            print(f"  denial present: {REVISED_DENIALS[lang]}")

        want = re.sub(r"\s+", "", REVISED_PROMISE[lang])
        if want not in flat:
            failures.append(f"{path.name}: missing the why-it-differs promise")
        else:
            print(f"  why-it-differs present: {REVISED_PROMISE[lang]}")

        # BOTH numbers on the page. This is the document's whole job: a
        # customer holding the quotation must be able to check the new figure
        # against the old one without doing arithmetic. RM552.00 is the curtain
        # as quoted; the blind was measured exactly as quoted at RM162.00.
        for quoted in ("552.00", "162.00"):
            if quoted not in flat:
                failures.append(
                    f"{path.name}: the quoted RM{quoted} is not on the page"
                )
        print("  quoted amounts present alongside the final ones")


        if "pending" in stem:
            # Server-issued, so it must say so rather than invent one.
            if "pendingsync" not in flat.lower():
                failures.append(
                    f"{path.name}: an unsynced order must print 'pending sync'"
                )
            else:
                print("  unsynced order says pending sync")
            if "MLK-" in flat:
                failures.append(
                    f"{path.name}: an order number was fabricated on device"
                )
        else:
            if "MLK-2609-0007" not in flat:
                failures.append(f"{path.name}: the order number is missing")

        if is_over:
            # A window that measured larger than quoted is named on the page.
            # Nothing about section 8.5 lets that be silent.
            markers = {
                "zh": "有窗口实测尺寸大于报价尺寸",
                "en": "measured larger than quoted",
                "ms": "diukur lebih besar daripada sebut harga",
            }
            want = re.sub(r"\s+", "", markers[lang])
            if want not in flat:
                failures.append(
                    f"{path.name}: an over-estimate line was not disclosed"
                )
            else:
                print("  over-estimate disclosed on the page")

        if lang == "zh":
            for want in ("修订订单", "客厅", "夜帘"):
                if want not in flat:
                    failures.append(
                        f"{path.name}: Chinese text {want!r} did not render"
                    )
            print("  Chinese glyphs extracted correctly")

    if not checked:
        print("no PDFs found", file=sys.stderr)
        return 1

    print()
    if failures:
        for f in failures:
            print(f"FAIL {f}")
        return 1
    print(f"all {checked} documents pass")
    return 0


sys.exit(main())
