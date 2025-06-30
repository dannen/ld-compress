#!/bin/bash

# Usage check
if [ "$#" -lt 1 ]; then
  echo "Usage: $0 <base_filename> [--force] [--clean]"
  exit 1
fi

BASE_NAME="$1"
FORCE=0
CLEAN=0

[[ "$2" == "--force" || "$3" == "--force" ]] && FORCE=1
[[ "$2" == "--clean" || "$3" == "--clean" ]] && CLEAN=1

[ "$FORCE" -eq 1 ] && echo "Running in non-interactive FORCE mode"
[ "$CLEAN" -eq 1 ] && echo "Cleanup mode enabled after completion"

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
      read -p "Skip [s], Overwrite [o], or Exit [e]? " CHOICE
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
  ld-decode "$RF_INPUT" "${BASE_NAME}" --ntsc || {
    echo "ld-decode failed"; exit 1;
  }
} || echo "Skipping initial ld-decode (Stage 2)"

# Stage 3: Perform Dropout Correction
echo "==> Stage 3: Performing Dropout Correction with ld-dropout-correct"
if ask_overwrite "${BASE_NAME}_corr.tbc"; then
  # ld-dropout-correct takes positional arguments for input and output.
  # The --method flag is not supported by the currently built C++ version.
  # This version will use its default correction algorithm.
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
  if [ ! -e "${BASE_NAME}_corr.tbc" ] || [ ! -e "${BASE_NAME}.tbc.json" ] || [ ! -e "${BASE_NAME}.pcm" ]; then
      echo "Error: Missing input files for encoding. Skipping Stage 5."
      exit 1
  fi

  # Pipe ld-chroma-decoder output directly to ffmpeg
  ld-chroma-decoder "${BASE_NAME}_corr.tbc" - \
    -f ntsc3d \
    --luma-nr 0.2 --chroma-gain 1.0 --chroma-nr 0.1 \
    --input-json "${BASE_NAME}.tbc.json" \
    --output-format rgb \
    | \
  ffmpeg $([ "$FORCE" -eq 1 ] && echo "-y") -fflags +genpts -thread_queue_size 512 \
    -f rawvideo -pix_fmt rgb48 -s 760x488 -r 30000/1001 -i - \
    -f s16le -ar 44100 -ac 2 -i "${BASE_NAME}.pcm" \
    -map 0:v:0 -map 1:a:0 \
    -c:v ffv1 -level 3 -coder 1 -context 1 -g 1 -slices 24 -slicecrc 1 -pix_fmt yuv444p \
    -vf "bwdif=mode=1:parity=-1:deint=all" \
    -c:a pcm_s16le \
    -aspect 4:3 -color_primaries smpte170m -color_trc smpte170m -colorspace smpte170m \
    "${BASE_NAME}_archival.mkv" || echo "Archival encoding failed or skipped"
} || echo "Skipping archival encoding (Stage 5)"

# File presence checks
[ ! -e "${BASE_NAME}.pcm" ] && echo "⚠️  Warning: PCM audio file missing: ${BASE_NAME}.pcm"
[ ! -e "${BASE_NAME}.tbc.json" ] && echo "⚠️  Warning: Chroma JSON missing: ${BASE_NAME}.tbc.json"
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
  ffmpeg $([ "$FORCE" -eq 1 ] && echo "-y") -i "${BASE_NAME}_archival.mkv" -i "${BASE_NAME}.srt" \
    -map 0 -map 1 -c copy -c:s srt "${BASE_NAME}_archival_with_subs.mkv" || \
    echo "Skipping subtitle mux"
else
  echo "No subtitles extracted or .srt file empty. Skipping subtitle mux."
fi

# Stage 8: Generate checksum
echo "==> Stage 8: Generating SHA-256 checksum"

CHECKSUM_FILE="${BASE_NAME}_archival.sha256"
if [ -e "$CHECKSUM_FILE" ]; then
  echo "Checksum file already exists: $CHECKSUM_FILE — skipping"
else
  sha256sum "${BASE_NAME}_archival.mkv" > "$CHECKSUM_FILE"
  echo "Checksum saved to $CHECKSUM_FILE"
fi

# Stage 9: Clean up intermediates
if [ "$CLEAN" -eq 1 ]; then
  echo "==> Stage 9: Cleaning intermediate files"
  # Removed _rgb.tbc from cleanup as it's no longer created
  rm -f "${BASE_NAME}.tbc" "${BASE_NAME}.pcm" "${BASE_NAME}.efm" "${BASE_NAME}.log" \
        "${BASE_NAME}.vbi.json" \
        "${BASE_NAME}_corr.tbc"
fi

# Done
echo "✅ All processing complete."
echo "🧪 You can analyze the TBC output with: ld-analyse ${BASE_NAME}_corr.tbc"
