#!/usr/bin/env python3
"""只读导出微信输入法（WeType）本机个人词库。

数据源：~/Library/Application Support/WeType/userDict/v5/<generation>/
  - *.ldb   LevelDB SSTable
  - *.log   LevelDB WAL（未落盘的写入）

只取 `!u_d_v_p!` 键族，载荷是 `<逗号分隔拼音>\\x01<UTF-8 词>`。
不写入源目录，不打开 LevelDB（避免恢复/压实），不需要第三方依赖。

用法：
  ./scripts/wetype-export.py --dry-run
  ./scripts/wetype-export.py --out work/dict-2026-11-23/wetype_terms.json
"""

import argparse
import glob
import json
import os
import struct
import sys

TABLE_MAGIC = 0xDB4775248B80FB57
KEY_FAMILY = b"!u_d_v_p!"
BLOCK_TRAILER = 5


# ---------------------------------------------------------------- varint

def read_varint(buf, pos):
    result = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not b & 0x80:
            return result, pos
        shift += 7


# ---------------------------------------------------------------- SSTable

def read_block(path, offset, size, stats):
    with open(path, "rb") as f:
        f.seek(offset)
        contents = f.read(size)
        trailer = f.read(BLOCK_TRAILER)
    if len(contents) != size or len(trailer) < 1:
        raise ValueError("short block read")
    ctype = trailer[0]
    if ctype != 0:
        stats["skipped_compressed"] += 1
        return None
    return contents


def parse_block(block):
    """Yield (key, value) from a block's entries."""
    if len(block) < 4:
        return
    num_restarts = struct.unpack("<I", block[-4:])[0]
    limit = len(block) - 4 - 4 * num_restarts
    pos = 0
    last = b""
    while pos < limit:
        shared, pos = read_varint(block, pos)
        non_shared, pos = read_varint(block, pos)
        vlen, pos = read_varint(block, pos)
        key = last[:shared] + block[pos:pos + non_shared]
        pos += non_shared
        value = block[pos:pos + vlen]
        pos += vlen
        last = key
        yield key, value


def iter_table(path, stats):
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        f.seek(size - 48)
        footer = f.read(48)
    magic = struct.unpack("<Q", footer[40:48])[0]
    if magic != TABLE_MAGIC:
        stats["bad_magic_files"] += 1
        return
    _, pos = read_varint(footer, 0)
    _, pos = read_varint(footer, pos)          # metaindex handle (unused)
    index_off, pos = read_varint(footer, pos)
    index_size, _ = read_varint(footer, pos)
    index = read_block(path, index_off, index_size, stats)
    if index is None:
        return
    for _, handle in parse_block(index):
        off, p = read_varint(handle, 0)
        bsize, _ = read_varint(handle, p)
        data = read_block(path, off, bsize, stats)
        if data is None:
            continue
        for key, value in parse_block(data):
            yield key, value


# ---------------------------------------------------------------- WAL

def iter_log(path, stats):
    with open(path, "rb") as f:
        buf = f.read()
    pos = 0
    pending = b""
    while pos + 7 <= len(buf):
        length = struct.unpack("<H", buf[pos + 4:pos + 6])[0]
        rtype = buf[pos + 6]
        start = pos + 7
        if rtype == 0:                            # zero padding to block end
            pos = (pos // 32768 + 1) * 32768
            continue
        payload = buf[start:start + length]
        if len(payload) != length:
            break
        pos = start + length
        if rtype == 1:                            # FULL
            batch = pending + payload
            pending = b""
            yield from parse_batch(batch, stats)
        elif rtype == 2:                          # FIRST
            pending = payload
        elif rtype == 3:                          # MIDDLE
            pending += payload
        elif rtype == 4:                          # LAST
            pending += payload
            batch = pending
            pending = b""
            yield from parse_batch(batch, stats)


def parse_batch(batch, stats):
    if len(batch) < 12:
        return
    pos = 12
    while pos < len(batch):
        tag = batch[pos]
        pos += 1
        klen, pos = read_varint(batch, pos)
        key = batch[pos:pos + klen]
        pos += klen
        if tag == 1:
            vlen, pos = read_varint(batch, pos)
            value = batch[pos:pos + vlen]
            pos += vlen
            yield key, value
        elif tag == 0:
            yield key, None
        else:
            stats["bad_wal_records"] += 1
            return


# ---------------------------------------------------------------- main

def db_directory():
    root = os.path.expanduser("~/Library/Application Support/WeType/userDict/v5")
    conf = os.path.join(root, "db_path.conf")
    if os.path.exists(conf):
        gen = open(conf, encoding="utf-8").read().strip()
        candidate = os.path.join(root, gen)
        if os.path.isdir(candidate):
            return candidate
    dirs = [d for d in glob.glob(os.path.join(root, "*")) if os.path.isdir(d)]
    if len(dirs) != 1:
        sys.exit(f"无法确定词库目录（候选 {len(dirs)} 个），请手工检查 {root}")
    return dirs[0]


def load_family(db_dir, stats):
    files = []
    for name in os.listdir(db_dir):
        if name.endswith(".ldb") or name.endswith(".log"):
            stem = name.rsplit(".", 1)[0]
            if stem.isdigit():
                files.append((int(stem), name.endswith(".log"), name))
    files.sort()                                  # SSTables first, WAL last

    live = {}
    seen = 0
    for _, is_log, name in files:
        path = os.path.join(db_dir, name)
        stats["files"] += 1
        entries = iter_log(path, stats) if is_log else iter_table(path, stats)
        for key, value in entries:
            if not key.startswith(KEY_FAMILY):
                continue
            payload = key[len(KEY_FAMILY):]
            seen += 1
            if value is None:
                live.pop(payload, None)
            else:
                live[payload] = value
    stats["family_records"] = seen
    return live


def decode(payload):
    # <拼音>\x01<词>[\x01<权重 blob>]
    parts = payload.split(b"\x01")
    if len(parts) < 2:
        return None
    pinyin, word = parts[0], parts[1]
    try:
        text = word.decode("utf-8")
        pinyin = pinyin.decode("utf-8")
    except UnicodeDecodeError:
        return None
    if not text or len(text) > 24:
        return None
    if "\n" in text or "\t" in text:
        return None
    return text, pinyin


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    db_dir = db_directory()
    stats = {
        "files": 0,
        "skipped_compressed": 0,
        "bad_magic_files": 0,
        "bad_wal_records": 0,
        "family_records": 0,
    }
    live = load_family(db_dir, stats)

    by_word = {}
    dropped = 0
    for payload in live:
        item = decode(payload)
        if item is None:
            dropped += 1
            continue
        text, pinyin = item
        by_word.setdefault(text, pinyin)

    words = sorted(by_word)
    cjk = sum(1 for w in words if all("\u4e00" <= c <= "\u9fff" for c in w))
    latin = sum(1 for w in words if any(c.isascii() and c.isalpha() for c in w))

    print(f"词库目录: {db_dir}")
    print(f"文件: {stats['files']}  压缩块跳过: {stats['skipped_compressed']}  "
          f"坏 magic: {stats['bad_magic_files']}  坏 WAL 记录: {stats['bad_wal_records']}")
    print(f"u_d_v_p 记录: {stats['family_records']}  当前有效: {len(live)}  "
          f"结构不符丢弃: {dropped}")
    print(f"去重后词条: {len(words)}  （纯中文 {cjk}，含拉丁字母 {latin}）")

    if args.out and not args.dry_run:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump(
                [{"word": w, "pinyin": by_word[w]} for w in words],
                f, ensure_ascii=False, indent=0,
            )
        os.chmod(args.out, 0o600)
        print(f"已写出 {args.out}（0600）")


if __name__ == "__main__":
    main()
