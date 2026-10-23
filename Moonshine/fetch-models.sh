#!/bin/sh
# Downloads the Moonshine Streaming (medium, English, quantised) model files that the app bundles.
# Run once from the project root:  sh Moonshine/fetch-models.sh
# Swap "medium" for "small" (about 138 MB instead of 268 MB) and update MoonshineModel.folder to use the small model.
set -e
SIZE="${1:-medium}"
BASE="https://download.moonshine.ai/model/${SIZE}-streaming-en/quantized_26_08_21"
DEST="$(dirname "$0")/${SIZE}-streaming-en"
mkdir -p "$DEST"
for f in streaming_config.json encoder.ort decoder_kv.ort adapter.ort frontend.weights.ort cross_kv.ort tokenizer.bin frontend.model.ort; do
  [ -s "$DEST/$f" ] || curl -fL -o "$DEST/$f" "$BASE/$f"
done
echo "Model files are in $DEST"
