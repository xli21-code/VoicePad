#!/usr/bin/env python3
"""从真实口述里挖别名候选：名字被听错的地方，一条一条列出来人工过。

只报证据，不改任何配置。加进 alias 之前人必须看一眼 —— 一个错的别名会把
另一个真实存在的名字静默改坏，这比不改更糟。

用法：
  ./scripts/alias-candidates.py
  ./scripts/alias-candidates.py --vocab ~/.voicepad/vocabulary.json
"""

import argparse
import collections
import difflib
import json
import os

PAIRS = os.path.expanduser("~/.voicepad/pairs.jsonl")


def load_names(path):
    vocab = json.load(open(os.path.expanduser(path), encoding="utf-8"))
    # 拼音/英文词也一并看：它们同样会以等长替换的形式出现
    return [t for t in vocab["terms"] if len(t) >= 2]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vocab", default="~/.voicepad/vocabulary.json")
    args = ap.parse_args()

    names = load_names(args.vocab)
    mentioned = collections.Counter()
    candidates = collections.Counter()
    rows = 0

    for line in open(PAIRS, encoding="utf-8"):
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        raw, polished = d.get("raw_asr") or "", d.get("polished") or ""
        # 统计覆盖要用全部口述：没开润色的那几条同样算说过。
        for n in names:
            if n in polished or n in raw:
                mentioned[n] += 1
        if not raw or not polished:
            continue
        rows += 1

        # 只接受等长替换：名字被听错时字数不变，这样对齐位置才对得上，
        # 也顺手排掉了「删掉一半句子」那类改写差异。
        sm = difflib.SequenceMatcher(None, raw, polished, autojunk=False)
        for tag, i1, i2, j1, j2 in sm.get_opcodes():
            if tag != "replace":
                continue
            heard, meant = raw[i1:i2], polished[j1:j2]
            if len(heard) != len(meant) or not (2 <= len(meant) <= 8):
                continue
            if any(meant in n or n in meant for n in names):
                candidates[(heard, meant)] += 1

    print(f"{rows} 条口述，提到词表词的 {sum(mentioned.values())} 处\n")

    if candidates:
        print("候选别名（需要人工确认再写入 vocabulary.json 的 aliases）:")
        for (heard, meant), n in candidates.most_common():
            print(f"  {heard} → {meant}   ×{n}")
    else:
        print("没有候选：目前没有名字在口述里被听错的记录。")

    quiet = [n for n in names if n not in mentioned]
    print(f"\n从未被口述过的词 {len(quiet)}/{len(names)}（没有数据，不是没有问题）:")
    print("  " + "、".join(quiet))


if __name__ == "__main__":
    main()
