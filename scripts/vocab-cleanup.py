#!/usr/bin/env python3
"""Reduce the vocabulary to word-level entries.

Every alias is applied as a regular expression over every dictation, so an alias that
captured a whole sentence is both useless (any rewording misses) and permanent (it runs
on every dictation forever). The learner now refuses to create those, but the file still
contains a few from before that guard existed — including one pair where a menu item was
read back as the "corrected" text.

Each pair is re-diffed with the same tokenisation the Swift learner uses (CJK characters
are single tokens, Latin runs are one token), so the result is the alias the learner
would have produced: 蒙字 → 蒙自, not 字 → 自.

A single CJK character with no content character next to it is dropped rather than kept:
「退 → 推」 looks harmless but rewrites every 退 in every dictation.

Usage:
  python3 scripts/vocab-cleanup.py            # report only
  python3 scripts/vocab-cleanup.py --apply    # back up, then rewrite
"""
import argparse
import json
import os
import re
import shutil
import time
import unicodedata

HOME = os.path.expanduser("~")
PATH = HOME + "/.voicepad/vocabulary.json"

SENTENCE_PUNCT = "。！？!?；;\n"
MAX_TOKENS = 8
MAX_TERM = 16
# Fixtures that leaked out of the test suite into the real file.
FIXTURE = re.compile(r"^test_")

STOP_CJK = set("的了在和或也都就会把被让给对向从到而但却又还才只很更最不没这那我你他她它们有为以及与之所做去来上下中里用着过要能可得")


def is_cjk(ch):
    v = ord(ch)
    return (0x4E00 <= v <= 0x9FFF or 0x3400 <= v <= 0x4DBF
            or 0x20000 <= v <= 0x2A6DF or 0xF900 <= v <= 0xFAFF
            or 0x3000 <= v <= 0x303F or 0xFF00 <= v <= 0xFFEF)


def tokenize(text):
    tokens, buf = [], ""
    for ch in text:
        if ch.isspace():
            if buf:
                tokens.append(buf); buf = ""
        elif is_cjk(ch):
            if buf:
                tokens.append(buf); buf = ""
            tokens.append(ch)
        else:
            buf += ch
    if buf:
        tokens.append(buf)
    return tokens


def is_punct(ch):
    return unicodedata.category(ch).startswith("P")


def content_neighbor(tokens, i, step):
    """The token at i that can anchor a single-character fix, or None.

    Punctuation does not count:「退，」→「推，」 would fire on any 退 before a comma, so
    it is not a word-level lesson. Function words do not count either.
    """
    j = i
    while 0 <= j < len(tokens):
        t = tokens[j]
        if len(t) != 1 or not is_cjk(t):
            return None
        if is_punct(t):
            j += step
            continue
        return t if t not in STOP_CJK else None
    return None


def diff_span(a, b):
    """Walk both token lists and return the first replacement (from, to, prefix, suffix)."""
    i = j = 0
    while i < len(a) and j < len(b) and a[i] == b[j]:
        i += 1; j += 1
    # common suffix, without overlapping the prefix
    si, sj = len(a), len(b)
    while si > i and sj > j and a[si - 1] == b[sj - 1]:
        si -= 1; sj -= 1
    return a[i:si], b[j:sj], a[:i], a[si:]


def clean_pair(alias):
    frm, to = alias["from"], alias["to"]
    if frm == to:
        return None, "identical"
    if FIXTURE.match(frm) or FIXTURE.match(to):
        return None, "test fixture, not a real correction"

    a, b = tokenize(frm), tokenize(to)
    del_t, ins_t, prefix, _ = diff_span(a, b)
    if not del_t or not ins_t:
        return None, "pure insert/delete, no replacement to learn"
    if len(del_t) > MAX_TOKENS or len(ins_t) > MAX_TOKENS:
        return None, f"span too long ({len(del_t)}/{len(ins_t)} tokens)"
    if any(p in SENTENCE_PUNCT for p in "".join(del_t + ins_t)):
        return None, "sentence punctuation"
    if re.sub(r"[\s\W_]", "", "".join(del_t)) == re.sub(r"[\s\W_]", "", "".join(ins_t)):
        return None, "punctuation only"

    # Same expansion rule as the learner: a lone CJK character borrows its neighbour so
    # the alias matches a word ("蒙字" → "蒙自") and not every occurrence of that character.
    if len(del_t) == 1 and len(ins_t) == 1 and len(del_t[0]) == 1 and is_cjk(del_t[0]) \
            and len(ins_t[0]) == 1 and is_cjk(ins_t[0]):
        idx = len(prefix)
        prev = content_neighbor(a, idx - 1, -1)
        if prev:
            del_t = [prev] + del_t
            ins_t = [prev] + ins_t
        else:
            nxt = content_neighbor(a, idx + 1, 1)
            if nxt:
                del_t = del_t + [nxt]
                ins_t = ins_t + [nxt]
            else:
                return None, "single CJK character with no word to anchor it"

    return {"from": "".join(del_t), "to": "".join(ins_t)}, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    data = json.load(open(PATH, encoding="utf-8"))
    aliases_in = data.get("aliases", [])
    terms_in = data.get("terms", [])

    kept, dropped, seen = [], [], set()
    for a in aliases_in:
        cleaned, reason = clean_pair(a)
        if cleaned is None:
            dropped.append((a, reason))
            continue
        key = (cleaned["from"].lower(), cleaned["to"].lower())
        if key in seen:
            dropped.append((a, "duplicate of %s → %s" % key))
            continue
        seen.add(key)
        if key != (a["from"], a["to"]):
            dropped.append((a, "narrowed to %s → %s" % key))
        kept.append(cleaned)

    terms_kept = []
    for t in terms_in:
        if FIXTURE.match(t) or len(t) > MAX_TERM or any(c in SENTENCE_PUNCT for c in t):
            dropped.append(({"from": t[:40], "to": "—"}, "term is a sentence"))
            continue
        if not any(x in t for x in (" ",)) or len(t) <= MAX_TERM:
            if t not in terms_kept:
                terms_kept.append(t)

    print(f"aliases {len(aliases_in)} → {len(kept)}    terms {len(terms_in)} → {len(terms_kept)}\n")
    if dropped:
        print("changes:")
        for a, reason in dropped:
            print(f"  - {a['from'][:44]!r} → {a['to'][:44]!r}")
            print(f"      {reason}")
    print("\naliases kept:")
    for a in kept:
        print(f"  · {a['from']} → {a['to']}")
    print("\nterms kept:")
    for t in terms_kept:
        print(f"  · {t}")

    if not args.apply:
        print("\n(dry run — re-run with --apply to write)")
        return 0

    backup = PATH + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copyfile(PATH, backup)
    data["aliases"] = kept
    data["terms"] = terms_kept
    with open(PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2, sort_keys=True)
    print(f"\nbackup: {backup}\nwritten: {PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
