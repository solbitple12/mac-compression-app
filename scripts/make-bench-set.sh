#!/bin/bash
# Writes the benchmark set to the folder given (default build/bench-set): about
# 27 MB of seeded text, CSV, logs, binary records, many small files and a
# larger incompressible chunk, plus the test corpus for already-compressed
# media. Seeded, so every run benchmarks the same bytes.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/build/bench-set}"
rm -rf "$out"
mkdir -p "$out"
cp -R "$root/TampCore/Tests/TampCoreTests/Corpus" "$out/corpus"

python3 - "$out" <<'PY'
import itertools, os, random, sys
out = sys.argv[1]
rng = random.Random(20260928)

# A Zipf-distributed vocabulary of made-up words reads like prose to a compressor.
syllables = [c + v for c in "bcdfghjklmnprstvwz" for v in "aeiou"] + ["th", "st", "qu", "er", "an"]
vocabulary = sorted({"".join(rng.choice(syllables) for _ in range(rng.randint(1, 4))) for _ in range(20000)})
cumulative = list(itertools.accumulate(1 / (rank + 1) for rank in range(len(vocabulary))))
def sentence():
    words = rng.choices(vocabulary, cum_weights=cumulative, k=rng.randint(5, 22))
    return " ".join(words).capitalize() + rng.choice([".", ".", ".", "?", "!"])
with open(os.path.join(out, "prose.txt"), "w") as f:
    size = 0
    while size < 10 * 2**20:
        paragraph = " ".join(sentence() for _ in range(rng.randint(2, 8))) + "\n\n"
        f.write(paragraph)
        size += len(paragraph)

with open(os.path.join(out, "table.csv"), "w") as f:
    f.write("id,timestamp,user,city,amount,status\n")
    cities = ["Seoul", "Busan", "Lisbon", "Oslo", "Lima", "Accra", "Hanoi", "Quito"]
    for i in range(110000):
        f.write(f"{i},{1_700_000_000 + i * 37},{rng.choice(vocabulary)},{rng.choice(cities)},"
                f"{rng.randint(1, 99999) / 100:.2f},{rng.choice(['ok', 'ok', 'ok', 'late', 'failed'])}\n")

with open(os.path.join(out, "server.log"), "w") as f:
    paths = ["/api/items", "/api/items/{}", "/login", "/static/app.js", "/health", "/search?q={}"]
    for i in range(45000):
        path = rng.choice(paths).format(rng.randint(1, 5000))
        f.write(f'{{"t":{1_700_000_000_000 + i * 113},"level":"{rng.choice(["info", "info", "warn", "error"])}",'
                f'"path":"{path}","ms":{rng.expovariate(1 / 40):.1f},"bytes":{rng.randint(100, 90000)}}}\n')

with open(os.path.join(out, "records.bin"), "wb") as f:
    for i in range(131072):
        f.write(i.to_bytes(4, "little") + rng.randint(0, 255).to_bytes(1, "little") * 8 + bytes(4))
    f.write(rng.randbytes(1 << 20))

# Already-compressed video or photo libraries are mostly incompressible bytes;
# a chunk this size (not just records.bin's 1 MB tail) shows that case's real
# throughput and memory rather than being lost in the compressible files' bulk.
with open(os.path.join(out, "incompressible.bin"), "wb") as f:
    f.write(rng.randbytes(4 * 2**20))

# A folder a photo or project export might look like: many small files, whose
# per-file overhead the single large files above don't exercise (see
# Estimator's own per-file sampling, TampCore/Sources/TampCore/Estimation/Estimator.swift).
small_files = os.path.join(out, "many-small-files")
os.makedirs(small_files, exist_ok=True)
extensions = ["txt", "json", "log", "csv"]
for i in range(400):
    name = f"item-{i:04d}.{extensions[i % len(extensions)]}"
    with open(os.path.join(small_files, name), "w") as f:
        f.write(" ".join(sentence() for _ in range(rng.randint(1, 4))))
PY
du -sh "$out"
