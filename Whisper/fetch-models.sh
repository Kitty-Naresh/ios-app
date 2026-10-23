#!/bin/sh
# Downloads the Whisper model files that the app bundles (from Hugging Face, ggerganov/whisper.cpp).
# Run once from the project root:   sh Whisper/fetch-models.sh          (small.en, about 350 MB, the accurate one)
#                                   sh Whisper/fetch-models.sh base     (base.en, about 190 MB, lighter and faster)
# Each size goes in its own folder: Whisper/small.en or Whisper/base.en. The app uses small.en if both are present.
# The CoreML encoder (the .mlmodelc folder) runs on the Neural Engine on a real device; the simulator uses the CPU.
set -e
# The whisper.cpp framework (prebuilt, with CoreML) goes in WhisperSetup/, which the Xcode project links.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d "$ROOT/WhisperSetup/build-apple/whisper.xcframework" ]; then
  mkdir -p "$ROOT/WhisperSetup"
  curl -fL -o "$ROOT/WhisperSetup/xcf.zip" "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip"
  (cd "$ROOT/WhisperSetup" && unzip -q -o xcf.zip && rm -f xcf.zip)
fi
SIZE="${1:-small}"
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
DEST="$(dirname "$0")/${SIZE}.en"
case "$SIZE" in
  small) BIN="ggml-small.en-q5_1.bin" ;;
  base)  BIN="ggml-base.en.bin" ;;
  *) echo "Use small or base"; exit 1 ;;
esac
ENC="ggml-${SIZE}.en-encoder.mlmodelc"
mkdir -p "$DEST"
[ -s "$DEST/$BIN" ] || curl -fL -o "$DEST/$BIN" "$BASE/$BIN"
if [ ! -d "$DEST/$ENC" ]; then
  curl -fL -o "$DEST/$ENC.zip" "$BASE/$ENC.zip"
  (cd "$DEST" && unzip -q -o "$ENC.zip" && rm -f "$ENC.zip")
fi
echo "Model files are in $DEST"
