#!/usr/bin/env python3
"""Replays the input-silence gate over the archived takes.

The gate in `Sources/VoicePad/Util/InputSignal.swift` drops a take before the ASR
stage when its peak stays below `peakFloor`. This script checks that floor against
every recording in `~/.voicepad/audio` and the transcripts in `history.sqlite`, and
reports the two numbers that matter:

  * false kills — archived dictations with real text that the gate would drop;
  * missed silences — takes that produced no speech and the gate would still send
    to the model.

Runs with the system python3, no dependencies:

    /usr/bin/python3 scripts/input-gate-regression.py [--floor 0.005]
"""

import argparse
import datetime
import glob
import math
import os
import sqlite3
import struct
import wave

HOME = os.path.expanduser("~")
AUDIO_DIR = os.path.join(HOME, ".voicepad", "audio")
HISTORY = os.path.join(HOME, ".voicepad", "history.sqlite")
# The take is matched to a transcript by timestamp; ASR + polish + paste adds a few
# seconds, so anything within a minute is the same dictation.
MATCH_WINDOW = 60
# Windows to test the floor against. The gate itself only looks at the active part of
# the buffer, which is the tail: the shorter the window, the less silence it averages
# in, so the 20% window is the pessimistic case for false kills.
WINDOWS = (1.0, 0.6, 0.2)


def parse_timestamp(value):
    value = value.replace("T", " ").replace("Z", "").split(".")[0]
    return datetime.datetime.strptime(value, "%Y-%m-%d %H:%M:%S").replace(
        tzinfo=datetime.timezone.utc
    )


def peaks(path):
    with wave.open(path) as handle:
        if handle.getnchannels() != 1 or handle.getframerate() != 16000:
            return None
        raw = handle.readframes(handle.getnframes())
    samples = struct.unpack("<%dh" % (len(raw) // 2), raw) if raw else ()
    if not samples:
        return None
    return {
        label: max(abs(value) for value in samples[int(len(samples) * (1 - keep)):])
        / 32768.0
        for label, keep in ((f"tail{keep}", keep) for keep in WINDOWS)
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--floor", type=float, default=0.005)
    args = parser.parse_args()

    connection = sqlite3.connect(HISTORY)
    transcripts = sorted(
        (parse_timestamp(stamp), text)
        for stamp, text in connection.execute("select timestamp, text from transcripts")
    )

    takes = []
    for path in sorted(glob.glob(os.path.join(AUDIO_DIR, "*.wav"))):
        values = peaks(path)
        if values is None:
            continue
        recorded_at = datetime.datetime.strptime(
            os.path.basename(path)[:15], "%Y%m%dT%H%M%S"
        ).replace(tzinfo=datetime.timezone.utc)
        nearest, distance = None, MATCH_WINDOW + 1
        for stamp, text in transcripts:
            gap = abs((stamp - recorded_at).total_seconds())
            if gap < distance:
                nearest, distance = text, gap
        if distance > MATCH_WINDOW:
            continue
        produced_text = any(character.isalnum() for character in nearest) and not nearest.startswith("（")
        takes.append((os.path.basename(path), produced_text, values))

    speech = [take for take in takes if take[1]]
    wordless = [take for take in takes if not take[1]]
    # A take with no words and no signal is what the gate exists for. A take with no
    # words but real level is not a silence — the model just produced punctuation out
    # of audio — and the "transcript has no letters" check already covers it.
    silent = [take for take in wordless if max(take[2].values()) < args.floor]
    audible_wordless = [take for take in wordless if max(take[2].values()) >= args.floor]
    print(
        f"floor={args.floor}  takes={len(takes)}  with_text={len(speech)}"
        f"  silent={len(silent)}  audible_wordless={len(audible_wordless)}"
    )

    failed = False
    for label in sorted({key for take in takes for key in take[2]}):
        quietest = min(take[2][label] for take in speech) if speech else 0
        loudest = max(take[2][label] for take in silent) if silent else 0
        false_kills = [take[0] for take in speech if take[2][label] < args.floor]
        missed = [take[0] for take in silent if take[2][label] >= args.floor]
        print(
            f"  {label:7s} quietest real speech={quietest:.4f}  loudest silent take={loudest:.4f}"
            f"  false_kills={len(false_kills)}  missed_silences={len(missed)}"
        )
        if false_kills or missed:
            failed = True
            for name in false_kills[:5]:
                print(f"    would drop real dictation: {name}")
            for name in missed[:5]:
                print(f"    would transcribe silence: {name}")

    if audible_wordless:
        print(
            "  audible but wordless (caught by the no-letters check, not by the gate): "
            + ", ".join(take[0] for take in audible_wordless[:5])
        )

    margin = min(take[2]["tail1.0"] for take in speech) / args.floor if speech else 0
    print(f"  margin over the quietest archived dictation: {margin:.1f}x")
    print("RESULT", "FAIL" if failed else "OK — no archived dictation is dropped")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
