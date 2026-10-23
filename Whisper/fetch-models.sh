#!/bin/sh
# Downloads the Whisper model files that the app bundles (from Hugging Face, ggerganov/whisper.cpp).
# Run from the project root:
#   sh Whisper/fetch-models.sh turbo         large-v3-turbo, 5-bit, 574 MB: the accurate text. This is what the app ships with: the
#                                            encoder runs on the GPU, so there is no 1.2 GB CoreML encoder in the app.
#   sh Whisper/fetch-models.sh turbo-coreml  the same plus its CoreML encoder (1.2 GB more), to compare Neural Engine against GPU
#   sh Whisper/fetch-models.sh turbo-f16     large-v3-turbo, 16-bit, 1.6 GB: for comparing (the 5-bit one wins if both are there)
#   sh Whisper/fetch-models.sh small         small.en, about 350 MB with its encoder: only for the optional "Whisper (quick)" engine
#   sh Whisper/fetch-models.sh base          base.en, about 190 MB, a lighter version of that
# Each model goes in its own folder under Whisper/ (large-v3-turbo, small.en, base.en); everything in Whisper/ is bundled into the app,
# so keep only what you want to ship. A CoreML encoder (the .mlmodelc folder) beside the model runs on the Neural Engine on a real
# device; without one the encoder runs on the GPU. The simulator always uses the CPU.
set -e
# The whisper.cpp framework (prebuilt, with CoreML) goes in WhisperSetup/, which the Xcode project links.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ ! -d "$ROOT/WhisperSetup/build-apple/whisper.xcframework" ]; then
  mkdir -p "$ROOT/WhisperSetup"
  curl -fL -o "$ROOT/WhisperSetup/xcf.zip" "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/whisper-b5454-xcframework.zip"
  (cd "$ROOT/WhisperSetup" && unzip -q -o xcf.zip && rm -f xcf.zip)
fi
SIZE="${1:-turbo}"
BASE="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
case "$SIZE" in
  small)     FOLDER="small.en";        BIN="ggml-small.en-q5_1.bin";         ENC="ggml-small.en-encoder.mlmodelc" ;;
  base)      FOLDER="base.en";         BIN="ggml-base.en.bin";               ENC="ggml-base.en-encoder.mlmodelc" ;;
  turbo)        FOLDER="large-v3-turbo"; BIN="ggml-large-v3-turbo-q5_0.bin";   ENC="" ;;
  turbo-coreml) FOLDER="large-v3-turbo"; BIN="ggml-large-v3-turbo-q5_0.bin";   ENC="ggml-large-v3-turbo-encoder.mlmodelc" ;;
  turbo-f16)    FOLDER="large-v3-turbo"; BIN="ggml-large-v3-turbo.bin";        ENC="" ;;
  *) echo "Use turbo, turbo-coreml, turbo-f16, small or base"; exit 1 ;;
esac
DEST="$(dirname "$0")/${FOLDER}"
mkdir -p "$DEST"
[ -s "$DEST/$BIN" ] || curl -fL -o "$DEST/$BIN" "$BASE/$BIN"
if [ -n "$ENC" ] && [ ! -d "$DEST/$ENC" ]; then
  curl -fL -o "$DEST/$ENC.zip" "$BASE/$ENC.zip"
  (cd "$DEST" && unzip -q -o "$ENC.zip" -x "__MACOSX/*" && rm -f "$ENC.zip")
fi
echo "Model files are in $DEST"
