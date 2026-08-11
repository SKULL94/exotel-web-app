#!/bin/bash

# Download Vosk models for real-time streaming STT
# Supports Hindi and English
# Models are downloaded automatically on first app launch,
# but you can pre-download them using this script.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MODELS_DIR="$PROJECT_DIR/assets/models"

echo "========================================"
echo "Vosk Model Downloader"
echo "Real-time Streaming STT (Hindi + English)"
echo "========================================"
echo ""

# Create models directory
mkdir -p "$MODELS_DIR"
cd "$MODELS_DIR"

# Hindi model (42MB) - supports Hindi + Hinglish
HINDI_MODEL="vosk-model-small-hi-0.22"
HINDI_URL="https://alphacephei.com/vosk/models/${HINDI_MODEL}.zip"

echo "Downloading Hindi model (~42MB)..."
echo "URL: $HINDI_URL"
echo ""

if [ -d "$HINDI_MODEL" ]; then
    echo "Hindi model already exists at $MODELS_DIR/$HINDI_MODEL"
    echo "Delete the folder to re-download."
else
    curl -L -O "$HINDI_URL"
    echo "Extracting..."
    unzip -q "${HINDI_MODEL}.zip"
    rm "${HINDI_MODEL}.zip"
    echo "Hindi model extracted to: $MODELS_DIR/$HINDI_MODEL"
fi

echo ""
echo "========================================"
echo "Download Complete!"
echo "========================================"
echo ""
echo "Model details:"
echo "  - Name: Vosk Small Hindi"
echo "  - Languages: Hindi, Hinglish (Hindi-English mix)"
echo "  - Size: ~42MB"
echo "  - Type: STREAMING (real-time, word-by-word)"
echo "  - Latency: ~100-200ms"
echo ""
echo "The model will be automatically loaded by the app."
echo "On Android, the model is downloaded on first launch."
echo ""
