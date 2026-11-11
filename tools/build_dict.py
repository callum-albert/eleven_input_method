#!/usr/bin/env python3
"""Build the pinyin dictionary bundled with the input method.

Inputs (downloaded once, cached in tools/data):
  - CC-CEDICT  : word -> pinyin readings (with tones) and definitions
  - jieba dict : word -> corpus frequency

Output:
  Resources/pinyin.bin

The binary format is documented in Sources/ElevenCore/Dictionary.swift.
Everything happens at build time; the shipped app reads a local file only.
"""

from __future__ import annotations

import gzip
import os
import re
import struct
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "tools", "data")
CEDICT = os.path.join(DATA, "cedict.txt.gz")
JIEBA = os.path.join(DATA, "jieba_dict.txt")
OUT = os.path.join(ROOT, "Resources", "pinyin.bin")

CEDICT_URL = "https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz"
JIEBA_URL = "https://cdn.jsdelivr.net/gh/fxsjy/jieba@master/jieba/dict.txt"

CJK_RANGES = ((0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF), (0x20000, 0x2FA1F))
LINE_RE = re.compile(r"^(\S+)\s+(\S+)\s+\[([^\]]+)\]\s+/(.*)/\s*$")
SYLLABLE_RE = re.compile(r"^[a-z]+$")


def download(url: str, path: str) -> None:
    if os.path.exists(path):
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    print(f"downloading {url}")
    with urllib.request.urlopen(url, timeout=120) as response, open(path, "wb") as handle:
        while True:
            chunk = response.read(1 << 16)
            if not chunk:
                break
            handle.write(chunk)


def is_chinese_word(word: str) -> bool:
    if not word:
        return False
    for char in word:
        code = ord(char)
        if not any(low <= code <= high for low, high in CJK_RANGES):
            return False
    return True


def toneless(syllable: str) -> str | None:
    syllable = syllable.strip().lower().replace("ü", "v").replace("u:", "v")
    syllable = re.sub(r"[0-9]+$", "", syllable)
    syllable = syllable.replace("ê", "e")
    if not syllable or not SYLLABLE_RE.match(syllable):
        return None
    return syllable


def load_frequencies(path: str) -> dict[str, int]:
    frequencies: dict[str, int] = {}
    with open(path, encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) < 2:
                continue
            word, count = parts[0], parts[1]
            try:
                value = int(count)
            except ValueError:
                continue
            if value > frequencies.get(word, 0):
                frequencies[word] = value
    return frequencies


def load_cedict(path: str):
    """Yields (simplified_word, key, syllables)."""
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rt", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            if line.startswith("#"):
                continue
            match = LINE_RE.match(line)
            if not match:
                continue
            _traditional, simplified, pinyin, _definitions = match.groups()
            if not is_chinese_word(simplified):
                continue
            raw_syllables = pinyin.split()
            syllables = [toneless(part) for part in raw_syllables]
            if not syllables or any(part is None for part in syllables):
                continue
            if len(syllables) != len(simplified):
                # Erhua and a few irregular entries do not align; skip them.
                continue
            key = "".join(syllables)  # type: ignore[arg-type]
            yield simplified, key, syllables


def main() -> int:
    download(CEDICT_URL, CEDICT)
    download(JIEBA_URL, JIEBA)

    frequencies = load_frequencies(JIEBA)

    # (key, word) -> frequency
    entries: dict[tuple[str, str], float] = {}
    for word, key, syllables in load_cedict(CEDICT):
        freq = frequencies.get(word)
        if freq is None:
            freq = 30 if len(word) <= 2 else 8
        entries[(key, word)] = max(entries.get((key, word), 0), float(freq))

        # "lv" is the conventional spelling, but many people type "lu" for ü.
        if "v" in key:
            alt = key.replace("v", "u")
            alt_freq = float(freq) * 0.35
            if entries.get((alt, word), 0) < alt_freq:
                entries[(alt, word)] = alt_freq

    # Cap absurd corpus counts so a single very common word cannot dominate.
    maximum = 9_000_000.0
    rows = [
        (key, word, min(freq, maximum))
        for (key, word), freq in entries.items()
        if key and word and freq > 0
    ]
    rows.sort(key=lambda row: row[0].encode("utf-8"))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "wb") as handle:
        handle.write(b"EVND")
        handle.write(struct.pack("<II", 1, len(rows)))
        for key, word, freq in rows:
            key_bytes = key.encode("utf-8")
            word_bytes = word.encode("utf-8")
            if len(key_bytes) > 0xFFFF or len(word_bytes) > 0xFFFF:
                continue
            handle.write(struct.pack("<H", len(key_bytes)))
            handle.write(key_bytes)
            handle.write(struct.pack("<H", len(word_bytes)))
            handle.write(word_bytes)
            handle.write(struct.pack("<f", freq))

    words = {word for _key, word, _freq in rows}
    keys = {key for key, _word, _freq in rows}
    print(f"wrote {OUT}")
    print(f"  entries: {len(rows)}")
    print(f"  unique keys: {len(keys)}")
    print(f"  unique words: {len(words)}")
    print(f"  max key length: {max(len(key) for key in keys)}")
    print(f"  size: {os.path.getsize(OUT) / 1_000_000:.1f} MB")

    for sample in ("goujian", "xian", "hang", "zhongjian", "nv"):
        found = [(key, word, freq) for key, word, freq in rows if key == sample]
        found.sort(key=lambda row: row[2], reverse=True)
        preview = ", ".join(f"{word}({freq:.0f})" for _key, word, freq in found[:8])
        print(f"  {sample}: {preview or '-'}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
