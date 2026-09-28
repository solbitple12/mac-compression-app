# Test corpus

Small sample files for the round-trip tests. Every file was generated for Tamp
(nothing is copied from elsewhere), so the corpus carries no third-party license.

| File | What it covers | Made with |
| --- | --- | --- |
| documents/report.txt, nested/table.csv | Compressible text | `scripts/make-corpus.sh` (seeded Python) |
| documents/nested/deeper/Ünïcode café.txt | Non-ASCII names and deep folders | same |
| documents/notes with spaces.md, empty.txt | Spaces in names, a zero-byte file | same |
| binary.dat | Half structured records, half random bytes | same |
| media/photo.jpg, diagram.png | Already-compressed images | FFmpeg test sources |
| media/tone.wav | Uncompressed audio | FFmpeg sine source |
| media/clip.mp4 | Short H.264 and AAC video | FFmpeg test sources |

The tests add what git can't hold (an empty folder, a symlink, an executable bit)
to their own copy at run time.
