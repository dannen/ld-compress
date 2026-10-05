#!/bin/bash
# Same pipeline as ld-compress.sh, but Stage 2 uses ld-decode-rust (NTSC only).

# Rust decoder binary and demod thread count (-j 9 benchmarked as fastest per CPU)
LD_DECODE_RUST="${LD_DECODE_RUST:-$HOME/laserdiscs/ld-decode-rust/target/release/ld-decode}"
LD_DECODE_THREADS="${LD_DECODE_THREADS:-9}"
# Optional start frame. The Rust decoder never regains sync if it loses it in
# spin-up noise at the start of a capture; set this to a frame inside the
# lead-in to skip the noise, e.g. LD_DECODE_START=145
LD_DECODE_START="${LD_DECODE_START:-}"
# Optional number of frames to decode (e.g. LD_DECODE_LENGTH=2700 for ~90s)
LD_DECODE_LENGTH="${LD_DECODE_LENGTH:-}"

if [ ! -x "$LD_DECODE_RUST" ]; then
  echo "Error: Rust ld-decode not found at $LD_DECODE_RUST"
  echo "Build it with: cd ~/laserdiscs/ld-decode-rust && cargo build --release"
  exit 1
fi

# Usage check
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <base_filename> [--force] [--clean] [--nodeint]"
  exit 1
fi

BASE_NAME="$1"
shift
FORCE=0
CLEAN=0
NODEINT=0

for ARG in "$@"; do
  case "$ARG" in
    --force) FORCE=1 ;;
    --clean) CLEAN=1 ;;
    --nodeint) NODEINT=1 ;;
  esac
done

[ "$FORCE" -eq 1 ] && echo "Running in non-interactive FORCE mode"
[ "$CLEAN" -eq 1 ] && echo "Cleanup mode enabled after completion"
[ "$NODEINT" -eq 1 ] && echo "Deinterlacing disabled (--nodeint)"

# Overwrite prompt helper
ask_overwrite() {
  local FILE="$1"
  if [ -e "$FILE" ]; then
    if [ "$FORCE" -eq 1 ]; then
      echo "Overwriting existing file: $FILE"
      return 0
    fi
    echo "File '$FILE' already exists."
    while true; do
      read -p "Skip [s], Overwrite [o], or Exit [e]? " CHOICE || {
        echo "No input available (end of input). Aborting."; exit 1;
      }
      case "$CHOICE" in
        [Ss]*) return 1 ;;
        [Oo]*) return 0 ;;
        [Ee]*) echo "Aborting."; exit 1 ;;
        *) echo "Invalid input. Please enter s, o, or e." ;;
      esac
    done
  else
    return 0
  fi
}

echo "==> Starting LaserDisc archival processing for: $BASE_NAME"

# Stage 1: Compress RF
echo "==> Stage 1: Compressing RF data (.lds → .ldf)"
if [ -e "${BASE_NAME}.ldf" ] || [ -e "${BASE_NAME}.flac.ldf" ]; then
  echo "File ${BASE_NAME}.ldf or .flac.ldf already exists. Skipping compression."
else
  if [ -e "${BASE_NAME}.lds" ]; then
    ld-compress -a "${BASE_NAME}.lds" "${BASE_NAME}" || {
      echo "ld-compress failed"; exit 1;
    }
  else
    echo "Error: '${BASE_NAME}.lds' not found. Skipping compression."
  fi
fi

# Stage 2: Decode RF to TBC format with dropout masks
echo "==> Stage 2: Decoding RF to TBC format with dropout masks"
# Determine the RF input file
RF_INPUT=""
if [ -e "${BASE_NAME}.lds" ]; then
  RF_INPUT="${BASE_NAME}.lds"
  echo "Using raw RF: ${BASE_NAME}.lds for initial decode."
elif [ -e "${BASE_NAME}.ldf" ]; then
  RF_INPUT="${BASE_NAME}.ldf"
  echo "Using compressed RF: ${BASE_NAME}.ldf for initial decode."
elif [ -e "${BASE_NAME}.flac.ldf" ]; then
  RF_INPUT="${BASE_NAME}.flac.ldf"
  echo "Using FLAC compressed RF: ${BASE_NAME}.flac.ldf for initial decode."
else
  echo "Error: No .lds, .ldf, or .flac.ldf file found for initial RF decode."
  exit 1
fi

# Use --dod to create dropout masks in JSON for subsequent correction
ask_overwrite "${BASE_NAME}.tbc" && {
  # ld-decode-rust is NTSC-only, so there is no --NTSC flag
  START_ARGS=()
  [ -n "$LD_DECODE_START" ] && START_ARGS=(-s "$LD_DECODE_START") && echo "Starting decode at frame $LD_DECODE_START"
  [ -n "$LD_DECODE_LENGTH" ] && START_ARGS+=(-l "$LD_DECODE_LENGTH") && echo "Decoding $LD_DECODE_LENGTH frames"
  "$LD_DECODE_RUST" -j "$LD_DECODE_THREADS" "${START_ARGS[@]}" "$RF_INPUT" "${BASE_NAME}" || {
    echo "ld-decode failed"; exit 1;
  }
} || echo "Skipping initial ld-decode (Stage 2)"

# The decode can end on an unpaired first field. ld-dropout-correct only writes
# whole frames but keeps the full field count in its JSON, which makes
# ld-process-vbi read past the end of _corr.tbc and abort. Drop the stray field
# from the metadata (the .tbc data past it is simply never read).
if [ -e "${BASE_NAME}.tbc.json" ]; then
  python3 - "${BASE_NAME}.tbc.json" <<'EOF' || { echo "Field count fix failed"; exit 1; }
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    meta = json.load(f)
fields = meta["fields"]
dropped = 0
while fields and len(fields) % 2 and fields[-1].get("isFirstField"):
    fields.pop()
    dropped += 1
if dropped:
    meta["videoParameters"]["numberOfSequentialFields"] = len(fields)
    with open(path + ".tmp", "w") as f:
        json.dump(meta, f)
    os.replace(path + ".tmp", path)
    print(f"Dropped {dropped} unpaired trailing field from {path} ({len(fields)} fields remain)")
EOF
fi

# Stage 3: Perform Dropout Correction
echo "==> Stage 3: Performing Dropout Correction with ld-dropout-correct"
if ask_overwrite "${BASE_NAME}_corr.tbc"; then
  # ld-dropout-correct takes positional arguments for input and output.
  # The --method flag is not supported by the currently built C++ version.
  # This version will use its default correction algorithm.
  # ld-dropout-correct refuses to overwrite, so remove the old output first
  rm -fv "${BASE_NAME}_corr.tbc" "${BASE_NAME}_corr.tbc.json"
  ld-dropout-correct "${BASE_NAME}.tbc" "${BASE_NAME}_corr.tbc" || {
    echo "ld-dropout-correct failed"; exit 1;
  }
else
  echo "Skipping dropout correction (Stage 3) as requested."
fi

# Post-check to ensure _corr.tbc exists before proceeding to Stage 4
if [ ! -e "${BASE_NAME}_corr.tbc" ]; then
    echo "Error: Required file ${BASE_NAME}_corr.tbc was not found after Stage 3. Aborting."
    exit 1
fi

# Stage 4: Process VBI (Outputting to a dedicated .vbi.json file)
echo "==> Stage 4: Processing VBI data"
VBI_OUTPUT_FILE="${BASE_NAME}.vbi.json"
VBI_INPUT_JSON="${BASE_NAME}_corr.tbc.json" # Input for ld-process-vbi

# Check if the primary input JSON for VBI processing exists. If not, cannot proceed.
if [ ! -e "$VBI_INPUT_JSON" ]; then
    echo "Error: Missing input JSON for VBI processing: $VBI_INPUT_JSON. Skipping VBI processing."
    # Create an empty .vbi.json as a placeholder if input is missing,
    # so subsequent stages might not immediately fail if they check for its presence.
    touch "$VBI_OUTPUT_FILE"
    echo "Skipping ld-process-vbi (Stage 4) due to missing input JSON."
else
    # Now, check for the *specific output file* of this stage.
    # ask_overwrite will test for its existence and prompt the user if needed.
    if ask_overwrite "$VBI_OUTPUT_FILE"; then
        # If we reach here, it means the user chose to proceed (overwrite or file didn't exist).
        echo "Running ld-process-vbi to extract VBI metadata to $VBI_OUTPUT_FILE with --nobackup."
        ld-process-vbi "${BASE_NAME}_corr.tbc" --output-json "$VBI_OUTPUT_FILE" --nobackup || {
            echo "ld-process-vbi failed"; exit 1;
        }
    else
        # If we reach here, it means ask_overwrite returned 1 (user chose 's' or 'e').
        echo "Skipping ld-process-vbi (Stage 4) as requested."
    fi
fi

# Stage 5: Chroma Decode, Deinterlace, and Encode
echo "==> Stage 5: Performing chroma decode, deinterlacing, and encoding"
ask_overwrite "${BASE_NAME}_archival.mkv" && { # Primary check for final MKV output
  echo "  -> Performing Chroma Decode and piping to FFmpeg"
  # Check if required input files for this stage are missing.
  if [ ! -e "${BASE_NAME}_corr.tbc" ] || [ ! -e "${BASE_NAME}_corr.tbc.json" ] || [ ! -e "${BASE_NAME}.pcm" ]; then
      echo "Error: Missing input files for encoding. Skipping Stage 5."
      exit 1
  fi

  # Pipe ld-chroma-decoder output directly to ffmpeg
  FFMPEG_VF_ARGS=()
  if [ "$NODEINT" -eq 0 ]; then
    FFMPEG_VF_ARGS=(-vf "bwdif=mode=1:parity=-1:deint=all")
  fi

  ld-chroma-decoder "${BASE_NAME}_corr.tbc" - \
    -f ntsc3d \
    --luma-nr 0.2 --chroma-gain 1.0 --chroma-nr 0.1 \
    --input-json "${BASE_NAME}_corr.tbc.json" \
    --output-format rgb \
    | \
  ffmpeg -nostdin $([ "$FORCE" -eq 1 ] && echo "-y") -fflags +genpts -thread_queue_size 512 \
    -f rawvideo -pix_fmt rgb48 -s 760x488 -r 30000/1001 -i - \
    -f s16le -ar 44100 -ac 2 -i "${BASE_NAME}.pcm" \
    -map 0:v:0 -map 1:a:0 \
    -c:v ffv1 -level 3 -coder 1 -context 1 -g 1 -slices 24 -slicecrc 1 -pix_fmt yuv444p \
    "${FFMPEG_VF_ARGS[@]}" \
    -c:a pcm_s16le \
    -aspect 4:3 -color_primaries smpte170m -color_trc smpte170m -colorspace smpte170m \
    "${BASE_NAME}_archival.mkv" || echo "Archival encoding failed or skipped"
} || echo "Skipping archival encoding (Stage 5)"

# File presence checks
[ ! -e "${BASE_NAME}.pcm" ] && echo "⚠️  Warning: PCM audio file missing: ${BASE_NAME}.pcm"
[ ! -e "${BASE_NAME}_corr.tbc.json" ] && echo "⚠️  Warning: Chroma JSON missing: ${BASE_NAME}_corr.tbc.json"
[ ! -e "${BASE_NAME}.vbi.json" ] && echo "⚠️  Warning: VBI data missing: ${BASE_NAME}.vbi.json"
[ ! -e "${BASE_NAME}_corr.tbc" ] && echo "⚠️  Warning: Corrected TBC file missing: ${BASE_NAME}_corr.tbc (Note: May not have had full correction applied)"


# Stage 6: Subtitle extraction
echo "==> Stage 6: Extracting subtitles"
if command -v ccextractor >/dev/null 2>&1; then
  ask_overwrite "${BASE_NAME}.srt" && \
  ccextractor "${BASE_NAME}_archival.mkv" -o "${BASE_NAME}.srt" || \
  echo "Skipping subtitle extraction"
else
  echo "⚠️  Warning: ccextractor not found, skipping subtitle extraction."
fi

# Stage 7: Subtitle mux
echo "==> Stage 7: Muxing subtitles into MKV"
if [ -e "${BASE_NAME}.srt" ] && [ -s "${BASE_NAME}.srt" ]; then
  ask_overwrite "${BASE_NAME}_archival_with_subs.mkv" && \
  ffmpeg -nostdin $([ "$FORCE" -eq 1 ] && echo "-y") -i "${BASE_NAME}_archival.mkv" -i "${BASE_NAME}.srt" \
    -map 0 -map 1 -c copy -c:s srt "${BASE_NAME}_archival_with_subs.mkv" || \
    echo "Skipping subtitle mux"
else
  echo "No subtitles extracted or .srt file empty. Skipping subtitle mux."
fi

# Stage 8: Generate checksum
echo "==> Stage 8: Generating SHA-256 checksum"

CHECKSUM_FILE="${BASE_NAME}_archival.sha256"
CHECKSUM_TARGETS=()
CHECKSUM_STALE=0
for MKV in "${BASE_NAME}_archival.mkv" "${BASE_NAME}_archival_with_subs.mkv"; do
  if [ -e "$MKV" ]; then
    CHECKSUM_TARGETS+=("$MKV")
    [ "$MKV" -nt "$CHECKSUM_FILE" ] && CHECKSUM_STALE=1
  fi
done

if [ "${#CHECKSUM_TARGETS[@]}" -eq 0 ]; then
  echo "No archival MKV found — skipping checksum"
elif [ -e "$CHECKSUM_FILE" ] && [ "$CHECKSUM_STALE" -eq 0 ]; then
  echo "Checksum file is up to date: $CHECKSUM_FILE — skipping"
else
  sha256sum "${CHECKSUM_TARGETS[@]}" > "$CHECKSUM_FILE"
  echo "Checksum saved to $CHECKSUM_FILE"
fi

# Stage 9: Clean up intermediates
if [ "$CLEAN" -eq 1 ]; then
  echo "==> Stage 9: Cleaning intermediate files"
  # Removed _rgb.tbc from cleanup as it's no longer created
  rm -f "${BASE_NAME}.tbc" "${BASE_NAME}.pcm" "${BASE_NAME}.efm" "${BASE_NAME}.log" \
        "${BASE_NAME}.vbi.json" "${BASE_NAME}.tbc.json" "${BASE_NAME}.tbc.db" \
        "${BASE_NAME}_corr.tbc" "${BASE_NAME}_corr.tbc.json"
fi

# Done
echo "✅ All processing complete."
echo "🧪 You can analyze the TBC output with: ld-analyse ${BASE_NAME}_corr.tbc"
