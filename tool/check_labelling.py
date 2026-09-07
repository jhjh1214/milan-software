"""The document labelling audit. SPEC.md §10.1, §11 Phase 7, CLAUDE.md rule 7.

    Documents this system prints are quotations, order confirmations and
    payment receipts. They must not:
      - carry the words "Tax Invoice" or "e-Invoice"
      - display a UIN, a validation QR code, or anything resembling one
      - imply they are a validated tax document

    Getting this wrong is a legal problem, not a labelling one.

SQL Account is the sole issuer of record. Two systems submitting one sale
produce two validated UINs and a 72-hour cancellation problem.

## What this checks, and what checks the rest

This is the **static** half: it reads source and data, in all three languages,
across every tree that can put words in front of a customer. It is cheap and it
runs on every push.

The half with teeth is `tool/check_pdf_text.py`, which renders the real PDFs and
extracts the text back out of them. That one proves the **positive** duty — that
each document denies being a tax invoice, in the reader's own language. A grep
cannot prove that, because the PDF embeds a subset font and stores glyph indices
rather than characters, so a search of the bytes passes whether or not the words
were printed.

Between them:

| Surface | Checked by |
|---|---|
| The quotation PDF, three languages | `check_pdf_text.py`, rendered |
| The revised order PDF, three languages | `check_pdf_text.py`, rendered |
| Every handset string (`*.arb`, three languages) | here |
| Handset source, as a backstop | here |
| Every dashboard screen, printable from a browser | here |
| The rate card's own `{zh, en, ms}` labels — they are printed on a quotation and an admin edits them | here |
| Any QR or barcode renderer, anywhere | here |
| The SQL Account export | **nothing yet — it does not exist.** Blocked on §13 E1 |

The backend is deliberately out of scope: it prints nothing. Every label it
serves comes from the rate card, which is checked here at its source.

## Why the rule is "the whole string", not "the phrase appears"

§10.1 forbids a document *carrying* those words — that is, using them as its own
label. It does not forbid mentioning them. "The customer asked for an e-invoice"
is correct copy on a form: MyInvois is what that document is called, and the
sentence is about the accounts system rather than about this app. Banning the
phrase outright would delete the very screen that exists to serve the rule.

So a string is a violation when the phrase **is** the string — a title, a
heading, a button — and not when the phrase sits inside a sentence. In a
dashboard template a heading is checked for containment as well, because a
heading is a label whatever else is in it.

That is a proxy, and it is stated rather than hidden: a sentence that implied
this app issues tax documents would pass here. What catches that is the rendered
denial in `check_pdf_text.py` and somebody reading the copy.

    python tool/check_labelling.py
    python tool/check_labelling.py --self-test
"""

from __future__ import annotations

import json
import pathlib
import re
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent

# This script prints Chinese. A Windows console defaults to cp1252, which
# cannot encode it, and a script that dies on its own progress output reports
# nothing at all. CI is UTF-8 and would never have seen it.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="replace")

#: The forbidden labels, in every language the app speaks. English alone would
#: be a check that cannot see two thirds of the product: a Malay heading reading
#: "Invois Cukai" is exactly as much of a legal problem as an English one, and
#: the handset defaults to Chinese.
FORBIDDEN = {
    "tax invoice": "en",
    "e-invoice": "en",
    "e invoice": "en",
    "einvoice": "en",
    "invois cukai": "ms",
    "e-invois": "ms",
    "e invois": "ms",
    "einvois": "ms",
    "税务发票": "zh",
    "电子发票": "zh",
    "稅務發票": "zh (traditional)",
    "電子發票": "zh (traditional)",
}

#: A validated tax document's identifiers. The UIN is LHDN's, issued to SQL
#: Account's submission; nothing here may show one or anything that reads like
#: one. Case-sensitive on the acronym so "ruin" and "sanguine" are not findings.
UIN_PATTERNS = [
    (re.compile(r"\bUIN\b"), "UIN"),
    (re.compile(r"unique identifier number", re.I), "Unique Identifier Number"),
]

#: Anything that renders a QR or a barcode. §10.1 forbids "a validation QR code,
#: or anything resembling one" — and on a printed quotation, any QR at all
#: resembles one. A dependency check would not do: `barcode` arrives as a
#: transitive dependency of the `pdf` package whether or not anybody uses it, so
#: what matters is whether the code reaches for it.
QR_PATTERNS = [
    re.compile(r"\bBarcodeWidget\b"),
    re.compile(r"\bBarcode\s*\."),
    re.compile(r"\bQrImage\b"),
    re.compile(r"\bQrPainter\b"),
    re.compile(r"qr_flutter"),
    re.compile(r"\bQRCode\b"),
    re.compile(r"\bqrcode\b", re.I),
    re.compile(r"<qr[-a-z]*[\s>]", re.I),
]

#: Generated mirrors of files already checked. Reporting both would print every
#: finding four times and bury the one that matters.
GENERATED = re.compile(r"\.g\.dart$|app_localizations.*\.dart$|\.freezed\.dart$")


def normalise(text: str) -> str:
    """One string as a label reads: case-folded, unpunctuated, unspaced."""
    text = text.strip().strip("：:.。!！?？*_-—–\"'“”「」《》()（）[]")
    text = re.sub(r"\s+", " ", text.strip())
    return text.casefold()


def is_forbidden_label(text: str) -> str | None:
    """The language of the forbidden label this string IS, or None."""
    return FORBIDDEN.get(normalise(text))


def _phrase_pattern(phrase: str) -> re.Pattern[str]:
    """One forbidden phrase, matched where it is a phrase and not a fragment.

    Bounded on both sides for the Latin ones, because a plain substring search
    for `e invoice` finds it inside *"details for th·e invoice"* — which is the
    correct copy on the one screen this whole area exists for. Chinese has no
    word boundary and needs none: 电子发票 is four characters that mean that.
    """
    if phrase.isascii():
        return re.compile(rf"(?<![a-z0-9]){re.escape(phrase)}(?![a-z0-9])")
    return re.compile(re.escape(phrase))


PHRASE_PATTERNS = {phrase: _phrase_pattern(phrase) for phrase in FORBIDDEN}


def contains_forbidden(text: str) -> str | None:
    """The first forbidden phrase this string mentions anywhere, or None."""
    flat = normalise(text)
    for phrase, pattern in PHRASE_PATTERNS.items():
        if pattern.search(flat):
            return phrase
    return None


def strip_dart_comments(source: str) -> str:
    """Whole-line `//`, `///` and block comments.

    A comment is not printed, and the rule is quoted verbatim in the two files
    that implement it. A *trailing* comment still counts, which errs the safe
    way: a line is dropped only when it is entirely a comment.
    """
    source = re.sub(r"/\*.*?\*/", "", source, flags=re.S)
    keep = [ln for ln in source.splitlines() if not re.match(r"\s*(//|\*)", ln)]
    return "\n".join(keep)


def strip_ts_comments(source: str) -> str:
    return strip_dart_comments(source)


def strip_html_comments(source: str) -> str:
    return re.sub(r"<!--.*?-->", "", source, flags=re.S)


STRING_LITERAL = re.compile(
    r"'((?:[^'\\\n]|\\.)*)'" r'|"((?:[^"\\\n]|\\.)*)"',
)


def literals(source: str) -> list[str]:
    """Every single-line string literal. Good enough for a backstop.

    Hard rule 8 and §8 already forbid a hardcoded user-visible string in a
    widget — every one comes from the ARB files, which are checked exactly.
    This exists so that breaking that rule does not also mean escaping this one.
    """
    found = []
    for match in STRING_LITERAL.finditer(source):
        found.append(match.group(1) if match.group(1) is not None else match.group(2))
    return found


def html_text_runs(source: str) -> list[str]:
    """Text between tags. Angular control flow blocks are tags enough."""
    without_tags = re.sub(r"<[^>]*>", "\x00", source)
    return [run for run in without_tags.split("\x00") if run.strip()]


HEADING = re.compile(r"<h[1-6][^>]*>(.*?)</h[1-6]>", re.S | re.I)


def label_maps(node: object) -> list[dict]:
    """Every `{zh, en, ms}` map anywhere in a JSON document.

    Found by shape rather than by key name. CLAUDE.md: *"Labels on data are a
    map, not parallel columns"* — so a map carrying all three languages is a
    label wherever it sits, and a check keyed on `"labels"` would miss the next
    one somebody adds under a different name.
    """
    found = []
    if isinstance(node, dict):
        values = [node.get(lang) for lang in ("zh", "en", "ms")]
        if all(isinstance(v, str) for v in values):
            found.append(node)
        for value in node.values():
            found.extend(label_maps(value))
    elif isinstance(node, list):
        for value in node:
            found.extend(label_maps(value))
    return found


def audit(root: pathlib.Path, *, counts: dict[str, int] | None = None) -> list[str]:
    """Every finding, as a line somebody can act on.

    ``counts`` is filled in with how many files each surface actually saw. A
    check that silently scanned nothing passes exactly like a clean tree does,
    and this one walks four directory trees by glob — one renamed directory and
    it would go on printing "ok" forever.
    """
    problems: list[str] = []
    seen: dict[str, int] = {"arb": 0, "dart": 0, "html": 0, "ts": 0, "card": 0}

    def rel(path: pathlib.Path) -> str:
        return path.relative_to(root).as_posix()

    def check_label(where: str, text: str) -> None:
        language = is_forbidden_label(text)
        if language is not None:
            problems.append(
                f"{where}: {text.strip()!r} is a label claiming to be a tax "
                f"document ({language}). §10.1: SQL Account is the sole issuer."
            )

    def check_uin(where: str, text: str) -> None:
        for pattern, name in UIN_PATTERNS:
            if pattern.search(text):
                problems.append(
                    f"{where}: shows a {name}. §10.1 forbids displaying one, "
                    f"or anything resembling one — it is LHDN's, issued to SQL "
                    f"Account's submission."
                )

    def check_qr(where: str, source: str) -> None:
        for pattern in QR_PATTERNS:
            if pattern.search(source):
                problems.append(
                    f"{where}: renders a QR or barcode ({pattern.pattern}). "
                    f"§10.1: no validation QR, and on a printed document any QR "
                    f"resembles one."
                )
                return

    # Every user-visible string on the handset, in all three languages. The
    # exact surface the rule is about, and the only one checked value by value.
    for path in sorted((root / "mobile" / "lib" / "l10n").glob("*.arb")):
        seen["arb"] += 1
        data = json.loads(path.read_text(encoding="utf-8"))
        for key, value in data.items():
            if key.startswith("@") or not isinstance(value, str):
                continue
            check_label(f"{rel(path)}:{key}", value)
            check_uin(f"{rel(path)}:{key}", value)

    # Handset source, as a backstop against a hardcoded string.
    for path in sorted((root / "mobile" / "lib").rglob("*.dart")):
        if GENERATED.search(path.name):
            continue
        seen["dart"] += 1
        source = strip_dart_comments(path.read_text(encoding="utf-8"))
        for text in literals(source):
            check_label(rel(path), text)
            check_uin(rel(path), text)
        check_qr(rel(path), source)

    # The dashboard. It prints nothing of its own, but every screen on it goes
    # through a browser's Ctrl+P the first time somebody wants a job on paper.
    dashboard = root / "dashboard" / "src"
    for path in sorted(dashboard.rglob("*.html")):
        seen["html"] += 1
        source = strip_html_comments(path.read_text(encoding="utf-8"))
        for run in html_text_runs(source):
            check_label(rel(path), run)
            check_uin(rel(path), run)
        for heading in HEADING.findall(source):
            text = re.sub(r"<[^>]*>", " ", heading)
            phrase = contains_forbidden(text)
            if phrase is not None:
                problems.append(
                    f"{rel(path)}: a heading reads {' '.join(text.split())!r}, "
                    f"which carries {phrase!r}. A heading is a label whatever "
                    f"else is in it."
                )
        check_qr(rel(path), source)

    for path in sorted(dashboard.rglob("*.ts")):
        if path.name.endswith(".spec.ts"):
            continue
        seen["ts"] += 1
        source = strip_ts_comments(path.read_text(encoding="utf-8"))
        for text in literals(source):
            check_label(rel(path), text)
            check_uin(rel(path), text)
        check_qr(rel(path), source)

    # The rate card. Its labels are printed on the quotation, and it is DATA --
    # an admin edits it and publishes, with no code change and nothing rebuilt.
    # Every other surface here is reviewed by somebody writing code; this one is
    # not, which makes it the likeliest place for a wrong word to arrive.
    for path in sorted((root / "shared").glob("*.json")):
        seen["card"] += 1
        data = json.loads(path.read_text(encoding="utf-8"))
        for labels in label_maps(data):
            for lang in ("zh", "en", "ms"):
                check_label(f"{rel(path)} ({lang})", labels[lang])
                check_uin(f"{rel(path)} ({lang})", labels[lang])

    for surface, count in seen.items():
        if count == 0:
            problems.append(
                f"the {surface} surface matched no files. Either a directory "
                f"moved or this check has been passing without reading "
                f"anything — which looks exactly like a clean tree."
            )

    if counts is not None:
        counts.update(seen)
    return problems


REGISTER = """
Surfaces, and what covers each:

  quotation PDF, zh/en/ms        rendered and read back — check_pdf_text.py
  revised order PDF, zh/en/ms    rendered and read back — check_pdf_text.py
  handset strings (*.arb)        here, every value, three languages
  handset source                 here, string literals, as a backstop
  dashboard screens              here, template text and headings
  rate card labels {zh,en,ms}    here — data, edited without a code review
  QR / barcode, anywhere         here

  SQL Account export             DOES NOT EXIST YET. §13 E1 is unanswered, so
                                 there is nothing to check. When it lands it is
                                 a printed surface and belongs above.
  payment receipt document       NOT PRINTED YET. Receipts are recorded and
                                 numbered; nothing renders one. §10.1 names it
                                 as a document, so it belongs above when it is.
"""


def main() -> int:
    counts: dict[str, int] = {}
    problems = audit(ROOT, counts=counts)
    print(REGISTER.strip())
    print()
    print("read: " + ", ".join(f"{n} {s}" for s, n in counts.items()))
    print()
    if problems:
        for problem in problems:
            print(f"FAIL {problem}")
        print()
        print("CLAUDE.md hard rule 7 is a legal constraint, not a preference.")
        return 1
    print("ok — nothing claims to be a tax document, and nothing shows a UIN or QR")
    return 0


# --------------------------------------------------------------------------
# Self-test. A check with no test is a check that passes for the wrong reason,
# and this one's whole value is that it fails when it should. Each case plants
# exactly one violation in a throwaway tree and asserts it is reported.
# --------------------------------------------------------------------------

CLEAN_ARB = {
    "@@locale": "en",
    "pdfNotAnInvoice": "This document is a quotation, not a tax invoice.",
    "buyerRequested": "The customer asked for an e-invoice",
}


def _tree(root: pathlib.Path) -> None:
    (root / "mobile" / "lib" / "l10n").mkdir(parents=True)
    (root / "mobile" / "lib" / "features").mkdir(parents=True)
    (root / "dashboard" / "src" / "app").mkdir(parents=True)
    (root / "shared").mkdir(parents=True)

    (root / "mobile" / "lib" / "l10n" / "app_en.arb").write_text(
        json.dumps(CLEAN_ARB), encoding="utf-8"
    )
    (root / "mobile" / "lib" / "features" / "quote_pdf.dart").write_text(
        "// Nothing printed may say Tax Invoice.\nconst t = 'Quotation';\n",
        encoding="utf-8",
    )
    (root / "dashboard" / "src" / "app" / "order.ts").write_text(
        "const heading = 'Customer details for the invoice';\n", encoding="utf-8"
    )
    (root / "dashboard" / "src" / "app" / "order.html").write_text(
        "<h2>Customer details for the invoice</h2>\n<p>Not a tax invoice.</p>\n",
        encoding="utf-8",
    )
    (root / "shared" / "card.json").write_text(
        json.dumps(
            {
                "rows": [
                    {"labels": {"zh": "夜帘", "en": "Night curtain", "ms": "Langsir"}}
                ]
            }
        ),
        encoding="utf-8",
    )


CASES = [
    (
        "an English label",
        "mobile/lib/l10n/app_en.arb",
        lambda p: p.write_text(
            json.dumps({**CLEAN_ARB, "title": "Tax Invoice"}), encoding="utf-8"
        ),
    ),
    (
        "a Malay label",
        "mobile/lib/l10n/app_en.arb",
        lambda p: p.write_text(
            json.dumps({**CLEAN_ARB, "title": "Invois Cukai"}), encoding="utf-8"
        ),
    ),
    (
        "a Chinese label",
        "mobile/lib/l10n/app_en.arb",
        lambda p: p.write_text(
            json.dumps({**CLEAN_ARB, "title": "税务发票"}, ensure_ascii=False),
            encoding="utf-8",
        ),
    ),
    (
        "a UIN on a handset string",
        "mobile/lib/l10n/app_en.arb",
        lambda p: p.write_text(
            json.dumps({**CLEAN_ARB, "uin": "UIN: {value}"}), encoding="utf-8"
        ),
    ),
    (
        "a hardcoded label in Dart",
        "mobile/lib/features/quote_pdf.dart",
        lambda p: p.write_text("const t = 'Tax Invoice';\n", encoding="utf-8"),
    ),
    (
        "a QR on a printed document",
        "mobile/lib/features/quote_pdf.dart",
        lambda p: p.write_text(
            "final w = pw.BarcodeWidget(data: uin);\n", encoding="utf-8"
        ),
    ),
    (
        "a dashboard heading",
        "dashboard/src/app/order.html",
        lambda p: p.write_text(
            "<h1>Order MLK-1 — Tax Invoice</h1>\n", encoding="utf-8"
        ),
    ),
    (
        "a dashboard label on its own",
        "dashboard/src/app/order.html",
        lambda p: p.write_text("<p>e-Invoice</p>\n", encoding="utf-8"),
    ),
    (
        "a rate card label an admin typed",
        "shared/card.json",
        lambda p: p.write_text(
            json.dumps(
                {"rows": [{"labels": {"zh": "电子发票", "en": "ok", "ms": "ok"}}]},
                ensure_ascii=False,
            ),
            encoding="utf-8",
        ),
    ),
]


def self_test() -> int:
    failures = []

    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "clean"
        root.mkdir()
        _tree(root)
        found = audit(root)
        if found:
            failures.append(f"a clean tree reported: {found}")
        else:
            print("ok  a clean tree passes (a denial and a mention are not labels)")

    # The failure this check is likeliest to have without anybody noticing:
    # a directory moves, every glob matches nothing, and it prints "ok" for
    # the rest of the project's life.
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "moved"
        root.mkdir()
        _tree(root)
        (root / "mobile" / "lib" / "l10n" / "app_en.arb").unlink()
        found = audit(root)
        if not any("matched no files" in f for f in found):
            failures.append("a surface that matched nothing was not reported")
        else:
            print("ok  a surface that reads nothing is a failure, not a pass")

    for name, target, mutate in CASES:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp) / "t"
            root.mkdir()
            _tree(root)
            mutate(root / target)
            found = audit(root)
            if not found:
                failures.append(f"{name}: planted in {target}, reported nothing")
            else:
                print(f"ok  {name} is caught")

    print()
    if failures:
        for failure in failures:
            print(f"FAIL {failure}")
        return 1
    print(f"all {len(CASES) + 2} self-test cases behave")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(self_test())
    sys.exit(main())
