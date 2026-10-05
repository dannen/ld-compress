# ld-compress

These scripts turn a Domesday Duplicator RF capture of an NTSC LaserDisc into
an archival FFV1/PCM MKV. They handle compression, decoding, dropout
correction, VBI, chroma decoding, captions and checksums.

There are two versions. They run the same pipeline and differ only in the
decoder used in Stage 2:

| Script | Stage 2 decoder | Notes |
|---|---|---|
| `ld-compress.sh` | Python ld-decode (`~/laserdiscs/ld-decode/ld-decode --NTSC`) | Reference decoder. Slow (~2–5 FPS) |
| `ld-compress-rust.sh` | `ld-decode-rust` (`~/laserdiscs/ld-decode-rust/target/release/ld-decode -j 9`) | Byte-identical output, roughly 9–20x faster (~43 FPS). **NTSC only** |

Use the Rust version unless you need PAL or are checking against the
reference decoder.

## Usage

Run the script from the folder that holds the capture. Pass the base name
**without an extension**:

```bash
cd /path/to/capture/folder
~/laserdiscs/ld-compress-rust.sh <base_name> [--nodeint] [--force] [--clean]
~/laserdiscs/ld-compress.sh      <base_name> [--nodeint] [--force] [--clean]
```

Example:

```bash
~/laserdiscs/ld-compress-rust.sh RF-Sample_2026-10-01_20-15-01_side1 --nodeint
```

Stage 2 reads the first input it finds, in this order: `<base_name>.lds`,
`<base_name>.ldf`, `<base_name>.flac.ldf`.

### Flags

Flags go after the base name, in any order.

| Flag | Effect |
|---|---|
| `--nodeint` | Skip `bwdif` deinterlacing. The output stays as 29.97 interlaced frames, about 44% smaller than the 59.94p deinterlaced output. See the [field-order note](#known-issues). |
| `--force` | Don't prompt. Overwrite every existing output (passes `-y` to ffmpeg). |
| `--clean` | Run Stage 9 at the end, which deletes the intermediates (see [Outputs](#outputs)). This includes `.vbi.json`. Use it only when you want a fresh start next time. |

### Environment variables

Set these before the command, e.g.
`LD_DECODE_START=145 ~/laserdiscs/ld-compress-rust.sh <base_name> --nodeint`.

| Variable | Script | Default | Purpose |
|---|---|---|---|
| `LD_DECODE_LENGTH` | both | (all) | Decode only N frames, e.g. `2700` ≈ 90 s for a quick test |
| `LD_DECODE_START` | rust | (0) | Start decoding at frame N. The Rust decoder never regains sync once it loses it in spin-up noise at the start of a capture. If a decode comes out nearly empty, set this to a frame inside the lead-in, e.g. `145` |
| `LD_DECODE_THREADS` | rust | `9` | Demod threads. `-j 9` benchmarked fastest on the 5800X3D |
| `LD_DECODE_RUST` | rust | `~/laserdiscs/ld-decode-rust/target/release/ld-decode` | Decoder binary. If it's missing, build it with `cd ~/laserdiscs/ld-decode-rust && cargo build --release` |

## Pipeline

| Stage | Tool | Input → output |
|---|---|---|
| 1. Compress RF | `ld-compress -a` | `.lds` → `.flac.ldf` (skipped if a `.ldf`/`.flac.ldf` already exists) |
| 2. Decode RF | ld-decode (Python or Rust) | RF → `.tbc`, `.tbc.json`, `.pcm`, `.efm`, `.log` (Rust also writes `.tbc.db`) |
| — Field fix | inline Python | Drops an unpaired trailing first field from `.tbc.json`. Without this, `ld-process-vbi` reads past the end of `_corr.tbc` and aborts |
| 3. Dropout correction | `ld-dropout-correct` | `.tbc` → `_corr.tbc`, `_corr.tbc.json` (any old outputs are removed first, because the tool refuses to overwrite) |
| 4. VBI | `ld-process-vbi --nobackup` | `_corr.tbc` → `.vbi.json` |
| 5. Chroma + encode | `ld-chroma-decoder -f ntsc3d` piped to `ffmpeg` | `_corr.tbc` + `.pcm` → `_archival.mkv` |
| 6. Captions | `ccextractor` | `_archival.mkv` → `.srt` |
| 7. Caption mux | `ffmpeg` | → `_archival_with_subs.mkv` (only if `.srt` is non-empty) |
| 8. Checksum | `sha256sum` | → `_archival.sha256` (covers both MKVs; regenerated only when an MKV is newer than it) |
| 9. Cleanup | `rm` | only with `--clean` |

Stage 5 encode settings:
- Chroma decoder: `ntsc3d --luma-nr 0.2 --chroma-gain 1.0 --chroma-nr 0.1`, RGB48 at 760x488.
- Video: FFV1 level 3, `yuv444p`, GOP 1, 24 slices with slice CRCs, 4:3, smpte170m colour tags.
- Optional deinterlace: `bwdif=mode=1:parity=-1:deint=all`.
- Audio: 44.1 kHz stereo PCM s16le, taken from the decoder's `.pcm`.

## Outputs

| File | Kept after `--clean`? |
|---|---|
| `<base>.flac.ldf` (compressed RF) | yes |
| `<base>_archival.mkv` | yes |
| `<base>_archival_with_subs.mkv` (if captions exist) | yes |
| `<base>.srt` | yes |
| `<base>_archival.sha256` | yes |
| `.tbc`, `.tbc.json`, `.tbc.db`, `_corr.tbc`, `_corr.tbc.json`, `.pcm`, `.efm`, `.log`, `.vbi.json` | no |

The original `.lds` is never deleted by the scripts.

## Re-running and the overwrite prompts

When an output already exists (and `--force` isn't set), the script asks:

```
File 'X' already exists.
Skip [s], Overwrite [o], or Exit [e]?
```

If you skip a stage, the next stage uses the existing file. To redo only some
stages, skip the ones before them. If every output exists, the prompts come
in this order:

1. `<base>.tbc` (Stage 2)
2. `<base>_corr.tbc` (Stage 3)
3. `<base>.vbi.json` (Stage 4)
4. `<base>_archival.mkv` (Stage 5)
5. `<base>.srt` (Stage 6)
6. `<base>_archival_with_subs.mkv` (Stage 7, only if the `.srt` is non-empty)

Stage 1 never prompts; it skips on its own if the `.ldf` exists.

You can pipe the answers in for an unattended partial re-run. For example,
this re-encodes the MKV only and redoes captions:

```bash
printf 's\ns\ns\no\no\n' | ~/laserdiscs/ld-compress-rust.sh <base_name> --nodeint
```

Both ffmpeg calls use `-nostdin`, so ffmpeg can't eat the piped answers. If the
input runs out at a prompt, the script aborts instead of looping.

## Requirements

- `ld-compress`, `ld-dropout-correct`, `ld-process-vbi`, `ld-chroma-decoder`,
  `ld-analyse` in `/usr/local/bin` (built from ld-decode 7.3.0 / vhs-decode,
  JSON metadata).
- `ffmpeg` and `ccextractor` (apt). Without `ccextractor`, Stages 6–7 are
  skipped with a warning.
- Python 3 (for the field-count fix).
- Python version: `~/laserdiscs/ld-decode/ld-decode`.
- Rust version: a release build of `~/laserdiscs/ld-decode-rust`.
- Disk: a full side needs hundreds of GB for the `.lds`, `.tbc` and
  `_corr.tbc` files together. Check free space before you start.

## Known issues

- **`--nodeint` MKVs are tagged progressive.** The content is interlaced, but
  the field order isn't set, so ffprobe reports `field_order=progressive` and
  some players won't deinterlace (you'll see combing). This is not fixed yet.
  A fix would add `setfield=tff` / `-field_order tt` to Stage 5, or
  `mkvpropedit --edit track:v1 --set flag-interlaced=1 --set field-order=1`
  on existing files. Verify the order with `idet` first, and regenerate the
  `.sha256` afterwards.
- **Disc frame numbers vs. capture frames.** `LD_DECODE_START` and
  `LD_DECODE_LENGTH` count capture frames from the start of the file, not the
  disc's VBI frame numbers.
- **Upstream ld-decode has moved to SQLite metadata.** These scripts expect the
  JSON-era tools (7.3.0). Upgrading the C++ tools will break Stages 3–5 until
  the scripts are adapted.

## Inspecting results

```bash
ld-analyse <base>_corr.tbc        # needs the intermediates (run without --clean)
ffprobe -hide_banner <base>_archival.mkv
sha256sum -c <base>_archival.sha256
```
