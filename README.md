LaserDisc Archival Processing Script (ld-compress.sh)

This script automates a multi-stage workflow for archiving LaserDisc content, focusing on video decoding, dropout correction, VBI data extraction, and final video encoding. It leverages various tools from the vhs-decode project and standard Linux utilities.
Table of Contents

    Introduction

    Features

    Prerequisites

    Installation & Setup

    Usage

    Workflow Stages

    Important Notes & Troubleshooting

    License

1. Introduction

ld-compress.sh is a Bash script designed to streamline the complex process of digitizing LaserDisc content. It takes raw RF captures (typically from a Domesday Duplicator) and processes them through several steps, including dropout correction, VBI data extraction, and encoding into a high-quality FFV1 MKV file, with optional subtitle extraction and muxing.

The script is designed to be interactive, prompting the user to skip or overwrite existing intermediate files, making it suitable for iterative processing or resuming interrupted workflows.
2. Features

    RF Data Compression: Converts raw .lds files to compressed .ldf (FLAC-compressed RF).

    RF Decoding: Decodes compressed RF data into .tbc (Time Base Corrected) format, generating associated JSON metadata.

    Dropout Correction: Applies dropout correction using ld-dropout-correct.

    VBI Data Processing: Extracts Vertical Blanking Interval (VBI) data (e.g., closed captions, timecodes) into a dedicated JSON file.

    Chroma Decoding & Encoding: Processes TBC data for chroma decoding, deinterlacing, and encodes the final video into an FFV1 MKV container.

    Audio Passthrough: Integrates PCM audio from the decoding stage into the final MKV.

    Subtitle Extraction & Muxing: Extracts closed captions (if present) and muxes them into a separate MKV.

    Checksum Generation: Creates a SHA-256 checksum for the archival MKV.

    Interactive Skipping: Prompts the user to skip or overwrite existing intermediate files for efficient re-runs.

    Force Mode: Allows non-interactive overwriting of existing files.

    Cleanup Mode: Removes intermediate files after successful completion.

3. Prerequisites

This script relies on a specific set of tools, primarily from the vhs-decode project, which has a hybrid structure (some tools are Python-based, others are C++ and require compilation).

    Operating System: Linux (Ubuntu/Debian-based distributions are assumed for package manager commands).

    vhs-decode Tools:

        Python Components (via pipx): ld-decode, ld-compress.

        C++ Components (via source build): ld-dropout-correct, ld-chroma-decoder, ld-process-vbi, ld-analyse.

    FFmpeg: Command-line multimedia framework.

    CCExtractor: Tool for extracting closed captions.

    Standard Utilities: sha256sum, rm, cp, touch, read, echo, ls, which (typically pre-installed).

4. Installation & Setup

Follow these steps carefully to ensure all necessary tools are installed and correctly configured in your system's PATH.
A. Clone the vhs-decode Repository

First, clone the vhs-decode repository, which contains both the Python scripts and the C++ source code for the ld-tools.

git clone https://github.com/oyvindln/vhs-decode.git
cd vhs-decode

B. Install Python Components (via pipx)

pipx is recommended for installing Python applications in isolated environments.

    Install pipx (if not already installed):

    python3 -m pip install --user pipx
    python3 -m pipx ensurepath

    You may need to restart your terminal or source ~/.bashrc for pipx to be in your PATH.

    Install vhs-decode Python tools:
    Navigate to the root of your cloned vhs-decode directory and install:

    cd /path/to/your/vhs-decode # e.g., ~/vhs-decode
    pipx install . --force

    This will install ld-decode, ld-compress, and other Python utilities into ~/.local/bin/.

C. Build and Install C++ Components

Many essential ld-tools (like ld-dropout-correct, ld-chroma-decoder, ld-process-vbi) are C++ applications within the vhs-decode repository that need to be compiled.

    Install Build Dependencies:

    sudo apt update
    sudo apt install build-essential cmake qtbase5-dev libqt5charts5-dev # Essential build tools and Qt libraries

    Note: Depending on your system and specific ld-tools features, you might need more Qt development libraries.

    Build the C++ tools:

    cd /path/to/your/vhs-decode # Ensure you are in the root of the cloned repo
    mkdir build_cpp # Create a dedicated build directory for C++ components
    cd build_cpp
    cmake .. # Configure the build
    make -j$(nproc) # Compile using all available CPU cores

    Install the C++ tools:

    sudo make install # This installs compiled executables to /usr/local/bin/

D. Install FFmpeg and CCExtractor

sudo apt install ffmpeg ccextractor

E. Configure PATH Environment Variable

It's crucial that your shell finds the correct versions of the ld-tools. pipx installs to ~/.local/bin/, while sudo make install defaults to /usr/local/bin/.

Ensure ~/.local/bin is at the beginning of your PATH to prioritize the pipx versions for ld-decode etc.

echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

Verify your installation:

which ld-decode # Should show /home/(username)/.local/bin/ld-decode
which ld-dropout-correct # Should show /usr/local/bin/ld-dropout-correct
which ld-chroma-decoder # Should show /usr/local/bin/ld-chroma-decoder
which ld-process-vbi # Should show /usr/local/bin/ld-process-vbi
which ffmpeg
which ccextractor

5. Usage

To run the script, navigate to its directory and execute it with your base filename.

./ld-compress.sh <base_filename> [--force] [--clean]

    <base_filename>: The base name of your LaserDisc capture files (e.g., LOGH-D3SA). The script expects files like <base_filename>.lds or <base_filename>.flac.ldf to exist.

    --force: (Optional) Runs in non-interactive mode, automatically overwriting any existing intermediate or final files.

    --clean: (Optional) Removes all intermediate files after successful completion of the entire pipeline.

Interactive Prompts:

For each stage that produces an output file, if that file already exists and --force is not used, the script will prompt:

File 'filename' already exists.
Skip [s], Overwrite [o], or Exit [e]?

    s: Skip this stage. The script will proceed to the next stage using the existing file.

    o: Overwrite the existing file. The stage will re-run.

    e: Exit the script immediately.

6. Workflow Stages

The script executes the following stages sequentially:
Stage 1: Compress RF Data (.lds → .ldf)

    Input: <base_filename>.lds (raw RF capture)

    Output: <base_filename>.flac.ldf (FLAC-compressed RF)

    Tool: ld-compress

Stage 2: Decode RF to TBC Format (.ldf → .tbc, creates .tbc.json)

    Input: <base_filename>.lds or <base_filename>.flac.ldf

    Output: <base_filename>.tbc (TBC video data), <base_filename>.pcm (PCM audio), <base_filename>.efm, <base_filename>.log, <base_filename>.tbc.json (JSON metadata, including dropout detection info).

    Tool: ld-decode

    Note: This version of ld-decode does not support the --dod flag for explicit dropout mask generation, so dropout correction relies on ld-dropout-correct's internal detection.

Stage 3: Perform Dropout Correction (.tbc → _corr.tbc)

    Input: <base_filename>.tbc, <base_filename>.tbc.json

    Output: <base_filename>_corr.tbc (corrected TBC video data)

    Tool: ld-dropout-correct

    Note: This ld-dropout-correct version does not support the --method flag (e.g., interfield+median) and uses its default correction algorithm.

Stage 4: Process VBI Data (_corr.tbc → .vbi.json)

    Input: <base_filename>_corr.tbc (TBC video data), <base_filename>_corr.tbc.json (input JSON metadata).

    Output: <base_filename>.vbi.json (dedicated JSON file containing extracted VBI data).

    Tool: ld-process-vbi

    Note: This stage now explicitly outputs VBI data to a separate .vbi.json file and uses the --nobackup flag to prevent conflicts with its internal backup mechanism.

Stage 5: Chroma Decode, Deinterlace, and Encoding (_corr.tbc → .mkv)

    Input: <base_filename>_corr.tbc, <base_filename>.tbc.json, <base_filename>.pcm

    Output: <base_filename>_archival.mkv (FFV1 encoded video with PCM audio)

    Tools: ld-chroma-decoder (pipes directly to FFmpeg), ffmpeg

    Note: ld-tbc2yuv is NOT used. ld-chroma-decoder outputs raw RGB data directly to ffmpeg via a pipe.

Stage 6: Subtitle Extraction (.mkv → .srt)

    Input: <base_filename>_archival.mkv

    Output: <base_filename>.srt (SRT subtitle file)

    Tool: ccextractor

    Note: If no captions are found in the source, an empty .srt file will be created.

Stage 7: Subtitle Muxing (.mkv + .srt → _archival_with_subs.mkv)

    Input: <base_filename>_archival.mkv, <base_filename>.srt

    Output: <base_filename>_archival_with_subs.mkv (MKV with muxed subtitles)

    Tool: ffmpeg

Stage 8: Generate Checksum (.mkv → .sha256)

    Input: <base_filename>_archival.mkv

    Output: <base_filename>_archival.sha256 (SHA-256 checksum file)

    Tool: sha256sum

Stage 9: Clean up Intermediates

    Action: Removes various intermediate files generated during the process if the --clean flag is used.

7. Important Notes & Troubleshooting

    Hybrid Toolset: Remember that vhs-decode is a mix of Python scripts (installed via pipx) and C++ binaries (compiled from source). Ensure both sets are correctly installed and your PATH prioritizes ~/.local/bin for the Python tools.

    ld-decode --dod: The ld-decode version installed via pipx (e.g., 0.3.5.2.dev94) does not support the --dod flag for explicit dropout mask generation. Dropout correction in Stage 3 relies on ld-dropout-correct's internal detection.

    ld-dropout-correct --method: The C++ ld-dropout-correct tool compiled from vhs-decode source does not support the --method flag. It uses its default correction algorithm.

    ld-process-vbi Output: ld-process-vbi now explicitly outputs to a separate *.vbi.json file. This file's presence is used for skipping Stage 4.

    ld-tbc2yuv Not Used: This script directly pipes the raw RGB output from ld-chroma-decoder to ffmpeg, eliminating the need for ld-tbc2yuv.

    ld-decode Sync Pulse Warnings: If ld-decode reports "Unable to find any sync pulses" or "Field phaseID sequence mismatch," it indicates potential issues with your raw RF capture, LaserDisc condition, or player stability. While the script will attempt to proceed, the resulting video quality may be compromised.

    Disk Space: Archiving LaserDiscs generates very large intermediate files. Ensure you have hundreds of gigabytes, potentially terabytes, of free disk space.

    Permissions: Always ensure your user has full read/write permissions in the working directory.

    FFmpeg Filters: The script uses bwdif for deinterlacing. If you encounter issues with other FFmpeg filters, verify they are compiled into your ffmpeg binary.

8. License

This script is provided under the terms of the GPLv3 license, consistent with the vhs-decode project it utilizes. Please refer to the LICENSE file in the vhs-decode repository for full details.
