#!/usr/bin/env python3
"""让模型给微信词库候选词打分：日常碎片 / 人名机构 / 行业术语。

输入  work/dict-2026-11-23/candidates.json
输出  work/dict-2026-11-23/classified.json（分批增量写，可续跑）

用法：
  ./scripts/wetype-classify.py --dry-run          # 只跑第一批，看结果
  ./scripts/wetype-classify.py                    # 全部跑完（已完成的批次跳过）
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request

BASE = os.environ.get("VOICEPAD_BASE_URL", "http://127.0.0.1:3425")
MODEL = os.environ.get("VOICEPAD_IMPORT_MODEL", "ollama-cloud/gemma4:31b")
WORK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                    "work", "dict-2026-11-23")
BATCH = 400

SYSTEM = """你是中文输入法词库的清洗员。输入是一批候选词，来自用户真实的打字记录。
逐个判断它属于哪一类，只输出 JSON，不要解释。

分类：
1 = 人名、机构、产品、品牌、地点等专有名词（例如：赵波、君信、盛冠达）
2 = 行业术语、专业黑话、技术词（例如：交叉验证、回撤、净值、指增、建模）
0 = 其他一切：日常词、虚词搭配、句子碎片、半截短语、错别字、无意义组合
  （例如：的利润、但没、是新的、有写、我们按、应该没错的）

判定要点：
- 只能整词成立的才算 1 或 2。读起来是半句话的一律 0，哪怕里面含专业词。
- 含「的、了、是、在、和、我、你、他、就、也、都、不、很、但、再、给、到、把、被、吗、呢、啊」等虚词且因此不成词的，一律 0。
- 拿不准时判 0。宁可漏掉，不要塞垃圾词进词表。

输出格式（只输出这一行 JSON）：
{"1":[索引...],"2":[索引...]}
索引是每行前面的编号。两个数组都可以为空。"""


def call(words, timeout=180):
    numbered = "\n".join(f"{i}\t{w}" for i, w in enumerate(words))
    body = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": numbered},
        ],
        "max_tokens": 2000,
        "temperature": 0,
    }
    req = urllib.request.Request(
        BASE.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        payload = json.load(r)
    return payload["choices"][0]["message"]["content"]


def pick(batch, indices):
    out = []
    for i in indices or []:
        try:
            i = int(i)
        except (TypeError, ValueError):
            continue
        if 0 <= i < len(batch):
            out.append(batch[i])
    return out


def extract_json(text):
    m = re.search(r"\{[\s\S]*\}", text)
    if not m:
        return None
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--start", type=int, default=0)
    args = ap.parse_args()

    candidates = json.load(open(os.path.join(WORK, "candidates.json"), encoding="utf-8"))
    out_path = os.path.join(WORK, "classified.json")
    done = {}
    if os.path.exists(out_path):
        done = json.load(open(out_path, encoding="utf-8"))

    batches = [candidates[i:i + BATCH] for i in range(0, len(candidates), BATCH)]
    if args.dry_run:
        batches = batches[args.start:args.start + 1]
        start_idx = args.start
    else:
        start_idx = 0

    for n, batch in enumerate(batches, start=start_idx):
        if str(n) in done:
            continue
        t0 = time.time()
        try:
            raw = call(batch)
        except Exception as e:
            print(f"batch {n}: 失败 {e}", file=sys.stderr)
            continue
        data = extract_json(raw)
        if data is None:
            print(f"batch {n}: 无法解析，原文前 200 字: {raw[:200]!r}", file=sys.stderr)
            continue
        done[str(n)] = {
            "words": batch,
            "names": pick(batch, data.get("1")),
            "terms": pick(batch, data.get("2")),
        }
        json.dump(done, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
        print(f"batch {n}: {len(batch)} 词 → 名 {len(done[str(n)]['names'])} "
              f"术语 {len(done[str(n)]['terms'])}  ({time.time() - t0:.1f}s)")
        if args.dry_run:
            print("  names:", "、".join(done[str(n)]["names"][:40]))
            print("  terms:", "、".join(done[str(n)]["terms"][:40]))


if __name__ == "__main__":
    main()
