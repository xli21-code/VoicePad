#!/usr/bin/env python3
"""Regression gate for the rewrite stage.

Runs the shipped polish prompt (dumped from the app binary, so it can never drift from
the code) over real dictations and checks the things that broke in practice:

  - failures: empty / punctuation-only / echo of the input
  - compression: the rewrite must actually be shorter than the input (median gain),
    without any single utterance losing half of itself (that would be summarising)
  - content loss: the rewriter deleting the second half of a sentence
  - term survival: English jargon keeping its spelling
  - filler left over
  - structure invented: lists/headings appearing before formatting is enabled
  - latency
  - cost: tokens and dollars per dictation, priced by the gateway's own model table

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
BASELINE_DIR = HOME + "/.voicepad/eval"


def baseline_path(contract: str) -> str:
    """One baseline per output contract: a different contract is a different prompt."""
    name = "regress_baseline.json" if contract == "neutral" else f"regress_baseline_{contract}.json"
    return os.path.join(BASELINE_DIR, name)

PUNCT = "，。！？、,.!?;；：: \t\n\r（）()《》“”\"'’‘-—…"
LIST_MARK = re.compile(r"^\s*(?:[-*•]|\d+[.、)]|#{1,6}\s)", re.M)
# When the speaker retracts themselves, deleting the retracted part is the correct
# behaviour, not content loss. Only unmarked deletion is suspicious. The last alternative
# is the garbled retraction ("不是他，不是这个，不是这个人"), which is one utterance's worth
# of residue and legitimately almost disappears; a single "不是" is not enough to match,
# because a plain negation must stay a gate.
CORRECTION = re.compile(r"不对|我是说|应该说|改成|换成|重说|说错了|算了|当我没说|没有或者|不是.{0,6}不是")
NUMBER = re.compile(r"\d+(?:[.,]\d+)?%?")
# Words that carry the meaning of a sentence. Losing one is not a style choice.
NEGATIONS = "不没别未无非"
RHETORICAL = re.compile(r"是不是|对不对|好不好|行不行|不是[^。！？]{0,20}吗")
# "五号六号" and "5号6号" are the same fact; comparing digits to Chinese numerals produced
# false positives, so number checks are skipped for utterances that use the latter.
CN_NUMERALS = "零一二三四五六七八九十百千万"
# Organise contracts may regroup, so the character-level "content kept" ratio stops being
# a fair test; these count facts instead.
PARAGRAPH = re.compile(r"\n\s*\n")
BULLET = re.compile(r"^\s*(?:[-*•]|\d+[.、)])\s", re.M)


def facts(text):
    """The parts of a dictation that must survive any amount of tidying.

    Numbers, plus a yes/no on negation. Negation is compared as a class rather than
    per-character: "不让我们有太多操作感" → "没有太多操作感" keeps the negation and only
    swaps the word, and rewordings like that are the whole point of the rewrite now.

    Rhetorical tags ("是不是…吗", "对不对") are stripped first: the rewrite is expected to
    turn "是不是要换模型" into "要换模型吗", which drops the 不 without dropping the question.

    Latin terms were tried and dropped: ASR spelling fixes (benchch → benchmark,
    sense voiceice → SenseVoice) look like losses to a token comparison, so term
    survival is measured separately by the term-rate metric.
    """
    statement = RHETORICAL.sub("", text)
    return {
        "numbers": {n.rstrip("%") for n in NUMBER.findall(text)},
        "negation": any(c in statement for c in NEGATIONS),
    }


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


# Filler that survives a rewrite is the thing the user actually hears as "still talking".
# It is counted together with the hedges that the prompt asks to delete.
HEDGE = re.compile(r"然后|就是|其实|所以说|那个|这一块|我觉得|可能|比较|大概|应该|稍微")


def hedge_count(s: str) -> int:
    return len(HEDGE.findall(s))


def load_pricing(cfg):
    """Per-token prices for the polish model, read from the gateway's own /v1/models.

    The gateway already knows what each model costs, so there is no price table here to
    rot. A model the gateway cannot price returns None: tokens are still counted, cost
    is reported as unknown instead of as zero.
    """
    try:
        with urllib.request.urlopen(cfg["base_url"] + "/v1/models", timeout=15) as resp:
            data = json.loads(resp.read())
    except Exception:
        return None
    for m in data.get("data") or []:
        if m.get("id") == cfg["model"]:
            p = m.get("pricing") or {}
            try:
                return {"prompt": float(p["prompt"]),
                        "completion": float(p["completion"]),
                        "cache_read": float(p["input_cache_read"])}
            except (KeyError, TypeError, ValueError):
                return None
    return None


def item_cost(usage, price):
    """(fresh_in, cached_in, out) tokens and dollars for one call.

    Cached prompt tokens are billed at the cache-read rate; the rest at the full prompt
    rate. Without a cache price they are conservatively priced as fresh.
    """
    ptok = int(usage.get("prompt_tokens") or 0)
    ctok = int(usage.get("completion_tokens") or 0)
    cached = int((usage.get("prompt_tokens_details") or {}).get("cached_tokens") or 0)
    cached = min(cached, ptok)
    if not price:
        return ptok - cached, cached, ctok, None
    cache_price = price.get("cache_read") or price["prompt"]
    cost = (ptok - cached) * price["prompt"] + cached * cache_price + ctok * price["completion"]
    return ptok - cached, cached, ctok, cost


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


def dump_prompt(binary: str, contract: str = "neutral") -> str:
    env = dict(os.environ)
    # The bare .build binaries need the bundled dylibs on the loader path.
    env["DYLD_LIBRARY_PATH"] = os.path.abspath("Frameworks/sherpa-onnx/lib")
    out = subprocess.run([binary, "--dump-polish-prompt", "--contract", contract],
                         capture_output=True, text=True,
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
    return ((choice["message"].get("content") or "").strip(), latency,
            choice.get("finish_reason"), data.get("usage") or {})


def evaluate(items, cfg, prompt, price=None):
    rows = []
    for item in items:
        raw = item["raw_asr"]
        try:
            out, latency, finish, usage = call_polish(cfg, prompt, raw)
        except Exception as exc:                      # network / model errors count as failures
            rows.append({"raw": raw, "out": "", "error": str(exc)[:120], "latency": None, "failed": True})
            continue

        fresh_in, cached_in, out_tokens, cost = item_cost(usage, price)
        s_in, s_out = squash(raw), squash(out)
        terms = english_terms(raw)
        term_hits = sum(1 for t in terms if t in out.lower())
        # "Unchanged" is legitimate when the input is already clean; only an empty or
        # contentless answer is a failure.
        failed = not s_out
        content_keep = lcs_len(s_out, s_in) / len(s_in) if s_in else 1.0
        fin, fout = facts(raw), facts(out)
        # Chinese numerals and Arabic digits are the same fact; rather than convert them,
        # the number comparison is skipped for utterances that use Chinese numerals. It has
        # to be skipped in both directions, otherwise the digits in the output look new.
        comparable = not any(c in CN_NUMERALS for c in raw)
        # A self-correction is supposed to delete what it retracts, so the check is skipped
        # for those utterances — otherwise the metric punishes the correct behaviour.
        kept_numbers = set() if not comparable else fin["numbers"] - fout["numbers"]
        lost = [] if CORRECTION.search(raw) else sorted(
            kept_numbers | ({NEGATIONS[0]} if fin["negation"] and not fout["negation"] else set()))
        new_numbers = sorted(fout["numbers"] - fin["numbers"]) if comparable else []
        rows.append({
            "raw": raw,
            "out": out,
            "latency": latency,
            "finish": finish,
            "failed": failed,
            "unchanged": s_out == s_in,
            "content_keep": round(content_keep, 3),
            # Trimming is the job now, so an identical output is the failure mode, not a
            # safe result. Positive = shorter than the input.
            "compression": round(1 - len(s_out) / len(s_in), 3) if s_in else 0.0,
            "hedges": hedge_count(out),
            # The threshold moved down because deleting filler lowers character overlap
            # without dropping meaning. Facts (numbers, negations) stay the hard gate.
            "content_lost": (len(s_in) >= 6 and content_keep < 0.35
                             and not CORRECTION.search(raw)),
            "terms": len(terms),
            "term_hits": term_hits,
            "fillers": filler_count(out),
            "structure_added": bool(LIST_MARK.search(out)) and not LIST_MARK.search(raw),
            "facts_lost": lost,
            "new_numbers": new_numbers,
            "paragraphs": len([p for p in PARAGRAPH.split(out) if p.strip()]),
            "bullets": len(BULLET.findall(out)),
            "tokens_in": fresh_in + cached_in,
            "tokens_out": out_tokens,
            "cost": cost,
        })
    return rows


def summarize(rows):
    lat = sorted(r["latency"] for r in rows if r["latency"])
    terms = sum(r.get("terms", 0) for r in rows)
    hits = sum(r.get("term_hits", 0) for r in rows)
    tin = sorted(r["tokens_in"] for r in rows if r.get("tokens_in") is not None)
    tout = sorted(r["tokens_out"] for r in rows if r.get("tokens_out") is not None)
    costs = [r["cost"] for r in rows if r.get("cost") is not None]
    med = lambda xs: round(statistics.median(xs)) if xs else None
    cost_per_call = round(sum(costs) / len(costs), 6) if costs else None
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
        "hedges_left": sum(r.get("hedges", 0) for r in rows),
        "compression_p50": round(statistics.median(
            [r["compression"] for r in rows if r.get("compression") is not None] or [0]), 3),
        "compression_mean": round(statistics.mean(
            [r["compression"] for r in rows if r.get("compression") is not None] or [0]), 3),
        "expanded": sum(1 for r in rows if (r.get("compression") or 0) < 0),
        # A rewrite that halves a dictation is summarising, not tidying.
        "over_compressed": sum(1 for r in rows
                               if (r.get("compression") or 0) > 0.7
                               and not CORRECTION.search(r["raw"])),
        "structure_added": sum(1 for r in rows if r.get("structure_added")),
        "facts_lost": sum(1 for r in rows if r.get("facts_lost")),
        "new_numbers": sum(len(r.get("new_numbers") or []) for r in rows),
        # Only organise contracts may exceed this; a plain dictation should not become a list.
        "over_structured": sum(1 for r in rows
                               if (r.get("paragraphs") or 0) > 3 or (r.get("bullets") or 0) > 5),
        "tokens_in_p50": med(tin),
        "tokens_out_p50": med(tout),
        # Local ASR has no marginal dollar cost; this is the LLM leg only.
        "cost_per_dictation_usd": cost_per_call,
        "cost_per_1k_usd": round(cost_per_call * 1000, 4) if cost_per_call is not None else None,
        "p50_ms": round(statistics.median(lat) * 1000) if lat else 0,
        "p90_ms": round(lat[int(len(lat) * 0.9) - 1] * 1000) if lat else 0,
    }


def gates(cur, base, contract="neutral"):
    checks = []
    checks.append(("失败率 ≤ 5%", cur["fail_rate"] <= 0.05, f"{cur['fail_rate']:.1%}"))
    # The prompt states a 10–30% budget; the median is the fleet-level reading of it.
    # Per-item variance is expected (a clean utterance has nothing to trim).
    checks.append(("压缩中位 ≥ 10%（不是原样返回）", cur["compression_p50"] >= 0.10,
                   f"{cur['compression_p50']:.0%}"))
    checks.append(("没有把话砍掉一半（单条 ≤ 70%）", cur["over_compressed"] == 0,
                   str(cur["over_compressed"])))
    if contract == "chat":
        # Regrouping breaks a character-level ratio without dropping anything, so the
        # organise contract is held to facts instead: numbers, negations, terms.
        checks.append(("事实不丢（数字/否定词，已排除自我纠正）", cur["facts_lost"] == 0,
                       str(cur["facts_lost"])))
        checks.append(("未过度结构化（段落 ≤3 / 条目 ≤5）", cur["over_structured"] == 0,
                       str(cur["over_structured"])))
    else:
        checks.append(("疑似掉内容 = 0（已排除自我纠正）", cur["content_lost"] == 0, str(cur["content_lost"])))
    # A number the speaker never said is a fabrication — but a model that "corrects" a
    # garbled proper noun (千问3AR → Qwen2-Audio) can invent one, so the gate holds the
    # count at the baseline instead of demanding zero.
    if "new_numbers" in base:
        checks.append(("编造数字不增加", cur["new_numbers"] <= base["new_numbers"],
                       f"{cur['new_numbers']} vs {base['new_numbers']}"))
    checks.append(("术语保留不退化 (≥ baseline-5pp)", cur["term_rate"] >= base["term_rate"] - 0.05,
                   f"{cur['term_rate']:.0%} vs {base['term_rate']:.0%}"))
    if contract != "chat":
        checks.append(("未擅自加结构化", cur["structure_added"] == 0, str(cur["structure_added"])))
    allowed = base["p50_ms"] * 1.5 + 200
    checks.append((f"p50 ≤ {allowed:.0f}ms", cur["p50_ms"] <= allowed, f"{cur['p50_ms']}ms"))
    # Cost moves for reasons quality metrics miss: a longer prompt, a chattier model, a
    # dropped cache hit. Only gated when both sides are priced — an unpriced model is
    # reported, not silently treated as free.
    # Only comparable against a baseline measured with the same contract: a code or
    # document contract is a different prompt by design, not a cost regression.
    if (cur.get("cost_per_dictation_usd") is not None and base.get("cost_per_dictation_usd")
            and cur.get("contract") == base.get("contract")):
        cap = base["cost_per_dictation_usd"] * 1.05
        checks.append((f"单次成本 ≤ baseline+5%", cur["cost_per_dictation_usd"] <= cap,
                       f"${cur['cost_per_dictation_usd']:.6f} vs ${base['cost_per_dictation_usd']:.6f}"))
    return checks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=None)
    ap.add_argument("--limit", type=int, default=0, help="only the most recent N items")
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--contract", default="neutral",
                    choices=["neutral", "chat", "document", "code", "email"],
                    help="check a per-app output contract instead of the default")
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
    price = load_pricing(cfg)
    prompt = dump_prompt(binary, args.contract)
    cfg["prompt_sha"] = hashlib.sha256(prompt.encode()).hexdigest()[:12]

    items = [json.loads(l) for l in open(PAIRS, encoding="utf-8") if l.strip()]
    items = [i for i in items if i.get("raw_asr") and i.get("audio_file")]
    if args.limit:
        items = items[-args.limit:]

    rows = evaluate(items, cfg, prompt, price)
    cur = summarize(rows)
    cur.update({"model": cfg["model"], "prompt_sha": cfg["prompt_sha"], "contract": args.contract,
                "priced": price is not None, "updated": time.strftime("%Y-%m-%d %H:%M")})

    baseline = baseline_path(args.contract)
    base = None
    if os.path.exists(baseline):
        base = json.load(open(baseline, encoding="utf-8"))

    checks = gates(cur, base, args.contract) if base else []
    if args.json:
        print(json.dumps({"current": cur, "baseline": base, "gates": checks,
                          "rows": rows}, ensure_ascii=False, indent=2))
    else:
        print(f"binary: {binary}")
        print(f"model: {cur['model']}   prompt: {cur['prompt_sha']}   items: {cur['items']}"
              f"   contract: {args.contract}")
        print(f"  失败 {cur['failures']}/{cur['items']}   原样返回 {cur['unchanged']}   掉内容 {cur['content_lost']}   "
              f"术语 {cur['term_hits']}/{cur['terms']} = {cur['term_rate']:.0%}")
        print(f"  压缩 中位 {cur['compression_p50']:.0%} / 均值 {cur['compression_mean']:.0%}   "
              f"变长 {cur['expanded']}   砍半 {cur['over_compressed']}   垫话残留 {cur['hedges_left']}")
        print(f"  残留填充词 {cur['fillers_left']}   擅自加结构 {cur['structure_added']}   "
              f"事实丢失 {cur['facts_lost']}   编造数字 {cur['new_numbers']}   "
              f"p50 {cur['p50_ms']}ms  p90 {cur['p90_ms']}ms")
        if cur["cost_per_dictation_usd"] is None:
            print(f"  成本：未知（网关未给 {cur['model']} 报价）；"
                  f"输入 {cur['tokens_in_p50']} tok / 输出 {cur['tokens_out_p50']} tok（中位）")
        else:
            print(f"  成本 ${cur['cost_per_dictation_usd']:.6f}/次 = ${cur['cost_per_1k_usd']:.2f}/千次"
                  f"   输入 {cur['tokens_in_p50']} tok / 输出 {cur['tokens_out_p50']} tok（中位）")
        if base:
            if base.get("prompt_sha") != cur["prompt_sha"]:
                print(f"  （prompt 有变化：{base.get('prompt_sha')} → {cur['prompt_sha']}）")
            if args.contract != base.get("contract", "neutral"):
                print(f"\n（成本 gate 跳过：本次 contract={args.contract}，基线 contract={base.get('contract', 'neutral')}）")
            print("\ngates:")
            for name, ok, value in checks:
                print(f"  {'PASS' if ok else 'FAIL'}  {name}  [{value}]")
        worst = sorted([r for r in rows if r.get("content_lost")], key=lambda r: r.get("content_keep", 1))[:5]
        if worst:
            print("\ncontent lost:")
            for r in worst:
                print(f"  keep={r['content_keep']:.2f}  {r['raw'][:44]} → {r['out'][:44]}")

    if args.update_baseline:
        os.makedirs(os.path.dirname(baseline), exist_ok=True)
        json.dump(cur, open(baseline, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        print(f"\nbaseline 已更新：{baseline}")
        return 0

    failed = [c for c in checks if not c[1]]
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
