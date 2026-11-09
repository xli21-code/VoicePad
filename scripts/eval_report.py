#!/usr/bin/env python3
"""Baseline report for the VoicePad ASR eval set.

Reads ~/.voicepad/pairs.jsonl (utterances with archived audio), aligns each
recording against the sentence list in docs/eval-script.md, and reports:

  - character error rate (CER) per utterance and overall
  - survival rate of embedded English terms (the metric that matters for
    zh-with-English-jargon dictation)
  - the worst utterances, so they can be hand-corrected

Writes ~/.voicepad/eval/ref.tsv (audio / asr / gold / hand_ref) — fill the
hand_ref column only for the rows you actually care about.

Usage: python3 scripts/eval_report.py [--script docs/eval-script.md]
"""
import argparse
import json
import os
import re
import sys
import unicodedata

PAIRS = os.path.expanduser("~/.voicepad/pairs.jsonl")
OUT_DIR = os.path.expanduser("~/.voicepad/eval")

# For the self-correction sentences (§4) the speaker says the false start out
# loud, so the *verbatim* transcript is the correct ASR output. What the
# speaker meant (false start removed) is a separate gold used to judge the
# rewrite step, not the recogniser.
CORRECTION_FINAL = {
    17: "我们先把尽调报告看完再定。",
    18: "这个量化策略的夏普是一点八。",
    19: "先接本地那个 Qwen3-ASR。",
    20: "仓位加到六成五。",
    21: "这个月的回撤是三点五个点。",
    22: "把那个语音输入的东西先关掉。",
}


def norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s).lower()
    s = re.sub(r"[\s，。！？、,\.!\?;；：:…\-—\"'“”‘’()（）\[\]]", "", s)
    return s


def strip_digits(s: str) -> str:
    """Number formatting (ITN on/off, 十 vs 10) is not what we are judging."""
    return re.sub(r"[0-9０-９一二三四五六七八九十百千萬万亿两]", "", s)


def strip_fillers(s: str) -> str:
    """Uh/um are transcribed on purpose — the rewriter removes them, not the ASR.

    Leaving them in would score a correct transcript as wrong.
    """
    s = re.sub(r"[呃嗯哦噢]+", "", s)
    s = re.sub(r"啊{2,}", "", s)
    return s


def edit_distance(a: str, b: str) -> int:
    if len(a) < len(b):
        a, b = b, a
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def load_script(path: str):
    """Returns ({number: sentence}, {number: section name}) from the markdown list."""
    items, sections, buf, num = {}, {}, [], None
    section = ""
    for line in open(path, encoding="utf-8"):
        h = re.match(r"^##\s*段\s*(\d+)\s*·\s*(.+?)\s*$", line.rstrip())
        if h:
            section = f"段{h.group(1)} {h.group(2)}"
            continue
        m = re.match(r"^(\d+)\.\s+(.*)$", line.rstrip())
        if m:
            if num is not None:
                items[num] = " ".join(buf).strip()
            num, buf = int(m.group(1)), [m.group(2)]
            sections[num] = section
        elif num is not None and line.strip() and not line.startswith("#"):
            buf.append(line.strip())          # wrapped continuation lines
        elif not line.strip() and num is not None:
            items[num] = " ".join(buf).strip()
            num, buf = None, []
    if num is not None:
        items[num] = " ".join(buf).strip()

    return items, sections


def similarity(asr: str, gold: str) -> float:
    a, b = norm(asr), norm(gold)
    a_bg = {a[i:i + 2] for i in range(len(a) - 1)}
    b_bg = {b[i:i + 2] for i in range(len(b) - 1)}
    if not a_bg or not b_bg:
        return 0.0
    return len(a_bg & b_bg) / len(a_bg | b_bg)


def best_match(asr: str, items: dict, min_no: int, uses: dict):
    """Align to a script sentence, keeping the order (the user read them in order).

    Candidates before `min_no` are rejected so a retake cannot jump back to an
    earlier sentence; a sentence may be used twice (retakes) but not more.
    """
    scores = {n: similarity(asr, t) for n, t in items.items()}

    # A clear content match wins even if it points backwards — people retake a
    # sentence after moving on, and those retakes must land on their own number.
    clear = [(s, n) for n, s in scores.items() if s >= 0.5 and uses.get(n, 0) < 2]
    if clear:
        s, n = max(clear)
        return n, s

    ordered = [(s, n) for n, s in scores.items() if n >= min_no and uses.get(n, 0) < 2]
    if ordered:
        s, n = max(ordered)
        return n, s
    s, n = max((s, n) for n, s in scores.items())
    return n, s


def english_terms(text: str):
    return [t for t in re.findall(r"[A-Za-z][A-Za-z0-9\-\.']*", text)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", default="docs/eval-script.md")
    args = ap.parse_args()

    items, sections = load_script(args.script)
    rows = [json.loads(l) for l in open(PAIRS, encoding="utf-8") if l.strip()]
    rows = [r for r in rows if r.get("audio_file")]

    results, used, last = [], {}, 0
    for r in sorted(rows, key=lambda r: r["ts"]):
        n, score = best_match(r["raw_asr"], items, last, used)
        gold = items.get(n, "")
        a, b = norm(r["raw_asr"]), norm(gold)
        at, bt = strip_fillers(strip_digits(a)), strip_fillers(strip_digits(b))
        dist = edit_distance(a, b) if b else 0
        dist_t = edit_distance(at, bt) if bt else 0
        term_hits = sum(1 for t in english_terms(gold) if t.lower() in r["raw_asr"].lower())
        term_total = len(english_terms(gold))
        results.append(dict(
            audio=r["audio_file"], dur=r["audio_duration_s"], asr=r["raw_asr"],
            script_no=n, section=sections.get(n, ""), match=round(score, 2), gold=gold,
            cer=dist / len(b) if b else None,
            cer_text=dist_t / len(bt) if bt else None,
            gold_final=CORRECTION_FINAL.get(n, gold),
            terms=f"{term_hits}/{term_total}",
        ))
        if n is not None:
            used[n] = used.get(n, 0) + 1
            last = max(last, n)

    scored = [r for r in results if r["cer"] is not None]
    total_err = sum(edit_distance(norm(r["asr"]), norm(r["gold"])) for r in scored)
    total_len = sum(len(norm(r["gold"])) for r in scored)
    overall = total_err / total_len if total_len else 0
    err_t = sum(edit_distance(strip_fillers(strip_digits(norm(r["asr"]))),
                              strip_fillers(strip_digits(norm(r["gold"])))) for r in scored)
    len_t = sum(len(strip_fillers(strip_digits(norm(r["gold"])))) for r in scored)
    overall_t = err_t / len_t if len_t else 0
    term_hits = sum(int(r["terms"].split("/")[0]) for r in results)
    term_total = sum(int(r["terms"].split("/")[1]) for r in results)

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(os.path.join(OUT_DIR, "ref.tsv"), "w", encoding="utf-8") as f:
        f.write("audio\tdur_s\tscript_no\tcer\tterms\tgold_asr\tgold_final\thand_ref\n")
        for r in results:
            cer = "" if r["cer"] is None else f"{r['cer']:.2f}"
            f.write(f"{r['audio']}\t{r['dur']:.1f}\t{r['script_no']}\t{cer}\t{r['terms']}"
                    f"\t{r['gold']}\t{r['gold_final']}\t\n")

    with open(os.path.join(OUT_DIR, "baseline.json"), "w", encoding="utf-8") as f:
        json.dump(dict(overall_cer=overall, overall_cer_no_digits=overall_t,
                       term_survival=(term_hits, term_total),
                       utterances=results), f, ensure_ascii=False, indent=2)

    print(f"recordings: {len(results)}   matched: {len(scored)}   "
          f"script sentences: {len(items)}")
    print(f"overall CER (char, incl. number formatting): {overall:.1%}")
    print(f"overall CER (char, digits + fillers ignored): {overall_t:.1%}   "
          f"english-term survival: {term_hits}/{term_total} = "
          f"{(term_hits / term_total if term_total else 0):.0%}")
    missing = sorted(set(items) - set(used))
    if missing:
        print(f"script sentences with no recording: {missing}")
    print("\nworst 12 (cer_no_digits desc):")
    for r in sorted(scored, key=lambda r: -(r["cer_text"] or 0))[:12]:
        print(f"  #{r['script_no']:<3} cer={r['cer_text']:.2f} terms={r['terms']:<5} {r['asr'][:56]}")
    print("\nper category:")
    cats = {}
    for r in scored:
        c = cats.setdefault(r["section"], {"err": 0, "len": 0, "terms": [0, 0]})
        c["err"] += edit_distance(strip_fillers(strip_digits(norm(r["asr"]))),
                                  strip_fillers(strip_digits(norm(r["gold"]))))
        c["len"] += len(strip_fillers(strip_digits(norm(r["gold"]))))
        h, t = r["terms"].split("/")
        c["terms"][0] += int(h)
        c["terms"][1] += int(t)
    for name, c in cats.items():
        th, tt = c["terms"]
        print(f"  {name:<28} cer={c['err'] / c['len'] if c['len'] else 0:5.1%}   "
              f"terms={th}/{tt}")

    print(f"\nwrote {OUT_DIR}/ref.tsv and baseline.json")


if __name__ == "__main__":
    sys.exit(main())
