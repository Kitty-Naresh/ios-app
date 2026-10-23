#!/bin/sh
# Downloads the Whisper model files that the app bundles (from Hugging Face, ggerganov/whisper.cpp).
# Run from the project root:
#   sh Whisper/fetch-models.sh              small.en, about 350 MB: the live text
#   sh Whisper/fetch-models.sh turbo        large-v3-turbo, 5-bit, about 1.8 GB with its CoreML encoder: the accurate text
#   sh Whisper/fetch-models.sh turbo-f16    large-v3-turbo, 16-bit, about 2.8 GB: for comparing (the 5-bit one wins if both are there)
#   sh Whisper/fetch-models.sh base         base.en, about 190 MB, a lighter live model (small.en wins if both are there)
# Each model goes in its own folder under Whisper/ (small.en, base.en, large-v3-turbo).
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
case "$SIZE" in
  small)     FOLDER="small.en";        BIN="ggml-small.en-q5_1.bin";         ENC="ggml-small.en-encoder.mlmodelc" ;;
  base)      FOLDER="base.en";         BIN="ggml-base.en.bin";               ENC="ggml-base.en-encoder.mlmodelc" ;;
  turbo)     FOLDER="large-v3-turbo";  BIN="ggml-large-v3-turbo-q5_0.bin";   ENC="ggml-large-v3-turbo-encoder.mlmodelc" ;;
  turbo-f16) FOLDER="large-v3-turbo";  BIN="ggml-large-v3-turbo.bin";        ENC="ggml-large-v3-turbo-encoder.mlmodelc" ;;
  *) echo "Use small, base, turbo or turbo-f16"; exit 1 ;;
esac
DEST="$(dirname "$0")/${FOLDER}"
mkdir -p "$DEST"
[ -s "$DEST/$BIN" ] || curl -fL -o "$DEST/$BIN" "$BASE/$BIN"
if [ ! -d "$DEST/$ENC" ]; then
  curl -fL -o "$DEST/$ENC.zip" "$BASE/$ENC.zip"
  (cd "$DEST" && unzip -q -o "$ENC.zip" -x "__MACOSX/*" && rm -f "$ENC.zip")
fi
echo "Model files are in $DEST"
