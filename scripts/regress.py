#!/usr/bin/env python3
"""Regression gate for the rewrite stage.

Runs the shipped polish prompt (dumped from the app binary, so it can never drift from
the code) over real dictations and checks the things that broke in practice:

  - failures: empty / punctuation-only / echo of the input
  - content loss: the rewriter deleting the second half of a sentence
  - term survival: English jargon keeping its spelling
  - filler left over
  - structure invented: lists/headings appearing before formatting is enabled
  - latency

Usage:
  python3 scripts/regress.py                    # check against the stored baseline
  python3 scripts/regress.py --update-baseline  # record current numbers as the baseline
  python3 scripts/regress.py --limit 15         # quick run on the most recent items
  python3 scripts/regress.py --json             # machine-readable output

Exit code is 1 when a gate fails, so it can be used as a pre-commit / CI step.
"""
import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.request

HOME = os.path.expanduser("~")
CONFIG = HOME + "/.voicepad/config.json"
PAIRS = HOME + "/.voicepad/pairs.jsonl"
BASELINE = HOME + "/.voicepad/eval/regress_baseline.json"

PUNCT = "，。！？、,.!?;；：: \t\n\r（）()《》“”\"'’‘-—…"
LIST_MARK = re.compile(r"^\s*(?:[-*•]|\d+[.、)]|#{1,6}\s)", re.M)
# When the speaker retracts themselves, deleting the retracted part is the correct
# behaviour, not content loss. Only unmarked deletion is suspicious.
CORRECTION = re.compile(r"不对|我是说|应该说|改成|换成|重说|说错了")


def squash(s: str) -> str:
    return "".join(c for c in s.lower() if c not in PUNCT)


def lcs_len(a: str, b: str) -> int:
    if not a or not b:
        return 0
    prev = [0] * (len(b) + 1)
    for ca in a:
        cur = [0]
        for j, cb in enumerate(b, 1):
            cur.append(prev[j - 1] + 1 if ca == cb else max(prev[j], cur[j - 1]))
        prev = cur
    return prev[-1]


def english_terms(s: str):
    return {t.lower() for t in re.findall(r"[A-Za-z][A-Za-z0-9\-\.]{2,}", s)}


def filler_count(s: str) -> int:
    return len(re.findall(r"[呃嗯哦噢]|然后然后|就是就是|那个那个", s))


def load_config():
    with open(CONFIG) as f:
        cfg = json.load(f)
    provider = cfg.get("provider") or {}
    models = cfg.get("models") or {}
    return {
        "base_url": (provider.get("base_url") or cfg.get("api_base_url") or "").rstrip("/"),
        "api_key": provider.get("api_key") or cfg.get("anthropic_api_key") or "",
        "model": models.get("polish") or cfg.get("model"),
    }


def dump_prompt(binary: str) -> str:
    env = dict(os.environ)
    # The bare .build binaries need the bundled dylibs on the loader path.
    env["DYLD_LIBRARY_PATH"] = os.path.abspath("Frameworks/sherpa-onnx/lib")
    out = subprocess.run([binary, "--dump-polish-prompt"], capture_output=True, text=True,
                         timeout=60, env=env)
    if out.returncode != 0 or not out.stdout.strip():
        sys.exit(f"could not dump the polish prompt from {binary}: {out.stderr[:200]}")
    return out.stdout.strip()


def call_polish(cfg, prompt: str, text: str, timeout=90):
    body = json.dumps({
        "model": cfg["model"],
        "max_tokens": 512,
        "temperature": 0.3,
        "reasoning_effort": "none",
        "messages": [{"role": "system", "content": prompt}, {"role": "user", "content": text}],
    }).encode()
    headers = {"Content-Type": "application/json"}
    if cfg["api_key"]:
        headers["Authorization"] = f"Bearer {cfg['api_key']}"
    req = urllib.request.Request(cfg["base_url"] + "/v1/chat/completions", data=body, headers=headers)
    started = time.time()
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = json.loads(resp.read())
    latency = time.time() - started
    choice = data["choices"][0]
    return (choice["message"].get("content") or "").strip(), latency, choice.get("finish_reason")


def evaluate(items, cfg, prompt):
    rows = []
    for item in items:
        raw = item["raw_asr"]
        try:
            out, latency, finish = call_polish(cfg, prompt, raw)
        except Exception as exc:                      # network / model errors count as failures
            rows.append({"raw": raw, "out": "", "error": str(exc)[:120], "latency": None, "failed": True})
            continue

        s_in, s_out = squash(raw), squash(out)
        terms = english_terms(raw)
        term_hits = sum(1 for t in terms if t in out.lower())
        # "Unchanged" is legitimate when the input is already clean; only an empty or
        # contentless answer is a failure.
        failed = not s_out
        content_keep = lcs_len(s_out, s_in) / len(s_in) if s_in else 1.0
        rows.append({
            "raw": raw,
            "out": out,
            "latency": latency,
            "finish": finish,
            "failed": failed,
            "unchanged": s_out == s_in,
            "content_keep": round(content_keep, 3),
            "content_lost": (len(s_in) >= 6 and content_keep < 0.5
                             and not CORRECTION.search(raw)),
            "terms": len(terms),
            "term_hits": term_hits,
            "fillers": filler_count(out),
            "structure_added": bool(LIST_MARK.search(out)) and not LIST_MARK.search(raw),
        })
    return rows


def summarize(rows):
    lat = sorted(r["latency"] for r in rows if r["latency"])
    terms = sum(r.get("terms", 0) for r in rows)
    hits = sum(r.get("term_hits", 0) for r in rows)
    return {
        "items": len(rows),
        "failures": sum(1 for r in rows if r.get("failed")),
        "unchanged": sum(1 for r in rows if r.get("unchanged")),
        "fail_rate": round(sum(1 for r in rows if r.get("failed")) / len(rows), 3) if rows else 0,
        "content_lost": sum(1 for r in rows if r.get("content_lost")),
        "content_keep_min": min([r.get("content_keep", 1) for r in rows] or [1]),
        "terms": terms,
        "term_hits": hits,
        "term_rate": round(hits / terms, 3) if terms else 1.0,
        "fillers_left": sum(r.get("fillers", 0) for r in rows),
        "structure_added": sum(1 for r in rows if r.get("structure_added")),
        "p50_ms": round(statistics.median(lat) * 1000) if lat else 0,
        "p90_ms": round(lat[int(len(lat) * 0.9) - 1] * 1000) if lat else 0,
    }


def gates(cur, base):
    checks = []
    checks.append(("失败率 ≤ 5%", cur["fail_rate"] <= 0.05, f"{cur['fail_rate']:.1%}"))
    checks.append(("疑似掉内容 = 0（已排除自我纠正）", cur["content_lost"] == 0, str(cur["content_lost"])))
    checks.append(("术语保留不退化 (≥ baseline-5pp)", cur["term_rate"] >= base["term_rate"] - 0.05,
                   f"{cur['term_rate']:.0%} vs {base['term_rate']:.0%}"))
    checks.append(("未擅自加结构化", cur["structure_added"] == 0, str(cur["structure_added"])))
    allowed = base["p50_ms"] * 1.5 + 200
    checks.append((f"p50 ≤ {allowed:.0f}ms", cur["p50_ms"] <= allowed, f"{cur['p50_ms']}ms"))
    return checks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--limit", type=int, default=0, help="only the most recent N items")
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    binary = args.binary
    if not binary:
        # Use the newest build: a stale bundle without the dump flag would silently
        # measure an old prompt.
        candidates = [c for c in ("dist/VoicePad.app/Contents/MacOS/VoicePad",
                                  "/Applications/VoicePad.app/Contents/MacOS/VoicePad",
                                  ".build/release/VoicePad", ".build/debug/VoicePad")
                      if os.path.exists(c)]
        if candidates:
            binary = max(candidates, key=os.path.getmtime)
    if not binary:
        sys.exit("build the app first: swift build")

    cfg = load_config()
    prompt = dump_prompt(binary)
    cfg["prompt_sha"] = hashlib.sha256(prompt.encode()).hexdigest()[:12]

    items = [json.loads(l) for l in open(PAIRS, encoding="utf-8") if l.strip()]
    items = [i for i in items if i.get("raw_asr") and i.get("audio_file")]
    if args.limit:
        items = items[-args.limit:]

    rows = evaluate(items, cfg, prompt)
    cur = summarize(rows)
    cur.update({"model": cfg["model"], "prompt_sha": cfg["prompt_sha"], "updated": time.strftime("%Y-%m-%d %H:%M")})

    base = None
    if os.path.exists(BASELINE):
        base = json.load(open(BASELINE, encoding="utf-8"))

    checks = gates(cur, base) if base else []
    if args.json:
        print(json.dumps({"current": cur, "baseline": base, "gates": checks,
                          "rows": rows}, ensure_ascii=False, indent=2))
    else:
        print(f"binary: {binary}")
        print(f"model: {cur['model']}   prompt: {cur['prompt_sha']}   items: {cur['items']}")
        print(f"  失败 {cur['failures']}/{cur['items']}   原样返回 {cur['unchanged']}   掉内容 {cur['content_lost']}   "
              f"术语 {cur['term_hits']}/{cur['terms']} = {cur['term_rate']:.0%}")
        print(f"  残留填充词 {cur['fillers_left']}   擅自加结构 {cur['structure_added']}   "
              f"p50 {cur['p50_ms']}ms  p90 {cur['p90_ms']}ms")
        if base:
            if base.get("prompt_sha") != cur["prompt_sha"]:
                print(f"  （prompt 有变化：{base.get('prompt_sha')} → {cur['prompt_sha']}）")
            print("\ngates:")
            for name, ok, value in checks:
                print(f"  {'PASS' if ok else 'FAIL'}  {name}  [{value}]")
        worst = sorted([r for r in rows if r.get("content_lost")], key=lambda r: r.get("content_keep", 1))[:5]
        if worst:
            print("\ncontent lost:")
            for r in worst:
                print(f"  keep={r['content_keep']:.2f}  {r['raw'][:44]} → {r['out'][:44]}")

    if args.update_baseline:
        os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
        json.dump(cur, open(BASELINE, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        print(f"\nbaseline 已更新：{BASELINE}")
        return 0

    failed = [c for c in checks if not c[1]]
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
