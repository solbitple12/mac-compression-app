#!/bin/bash
# Regenerates the test corpus in TampCore/Tests/TampCoreTests/Corpus.
# Needs python3 and an FFmpeg build with libopenh264 on PATH. The text and binary
# files are seeded, so they come out identical; the media files depend on the
# FFmpeg version. The corpus is committed, so this only runs when it changes.
set -euo pipefail

corpus="$(cd "$(dirname "$0")/.." && pwd)/TampCore/Tests/TampCoreTests/Corpus"
mkdir -p "$corpus/media" "$corpus/documents/nested/deeper"

python3 - "$corpus" <<'PY'
import os, random, sys
corpus = sys.argv[1]
rng = random.Random(20260928)
words = "archive block buffer checksum dictionary entropy frame header index level match offset parallel ratio stream table window".split()
lines = [" ".join(rng.choice(words) for _ in range(rng.randint(6, 14))).capitalize() + "." for _ in range(4000)]
open(os.path.join(corpus, "documents/report.txt"), "w").write("\n".join(lines) + "\n")
rows = ["id,name,size,ratio"] + [f"{i},file-{i:05d},{rng.randint(1, 10**7)},{rng.random():.4f}" for i in range(3000)]
open(os.path.join(corpus, "documents/nested/table.csv"), "w").write("\n".join(rows) + "\n")
open(os.path.join(corpus, "documents/nested/deeper/Ünïcode café.txt"), "w", encoding="utf-8").write("Grüße, 你好, こんにちは, 🗜️\n")
open(os.path.join(corpus, "documents/notes with spaces.md"), "w").write("# Notes\n\nA file name with spaces.\n")
open(os.path.join(corpus, "documents/empty.txt"), "w").close()
data = bytearray()
for i in range(8192):
    data += i.to_bytes(4, "little") + bytes([i % 251]) * 12
data += bytes(rng.getrandbits(8) for _ in range(128 * 1024))
open(os.path.join(corpus, "binary.dat"), "wb").write(data)
PY

ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
ff -f lavfi -i testsrc2=size=320x240:rate=1 -frames:v 1 -q:v 4 "$corpus/media/photo.jpg"
ff -f lavfi -i mandelbrot=size=256x192 -frames:v 1 "$corpus/media/diagram.png"
ff -f lavfi -i sine=frequency=440:duration=1:sample_rate=22050 -ac 1 -c:a pcm_s16le "$corpus/media/tone.wav"
ff -f lavfi -i testsrc2=size=160x120:rate=15 -f lavfi -i sine=frequency=660:duration=2 -t 2 \
   -c:v libopenh264 -b:v 150k -pix_fmt yuv420p -c:a aac -b:a 48k -movflags +faststart "$corpus/media/clip.mp4"
