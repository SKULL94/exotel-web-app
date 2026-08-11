"""
Vosk Speech-to-Text Processor for real-time streaming transcription.
Supports Hindi + English with ~100-200ms latency.
"""

import os
import json
import logging
import urllib.request
import zipfile
from typing import Optional, Tuple
from dataclasses import dataclass

logger = logging.getLogger(__name__)

# Try to import vosk
try:
    from vosk import Model, KaldiRecognizer, SetLogLevel
    VOSK_AVAILABLE = True
    SetLogLevel(-1)  # Suppress Vosk logs
except ImportError:
    VOSK_AVAILABLE = False
    logger.warning("Vosk not installed. Run: pip install vosk")


@dataclass
class TranscriptionResult:
    """Result from STT processing."""
    text: str
    is_final: bool  # True = complete utterance, False = partial (still speaking)
    confidence: float = 0.0
    language: str = "hi"


class VoskSTTProcessor:
    """
    Real-time streaming Speech-to-Text processor using Vosk.

    Features:
    - Streaming recognition with partial results
    - Hindi + English support
    - ~100-200ms latency
    - Automatic model download
    """

    # Model configuration
    MODEL_URL = "https://alphacephei.com/vosk/models/vosk-model-small-hi-0.22.zip"
    MODEL_NAME = "vosk-model-small-hi-0.22"

    def __init__(self, model_path: Optional[str] = None, sample_rate: int = 8000):
        """
        Initialize the Vosk STT processor.

        Args:
            model_path: Path to Vosk model directory. If None, auto-downloads.
            sample_rate: Audio sample rate (default 8000 for telephony)
        """
        self.sample_rate = sample_rate
        self.model: Optional[Model] = None
        self.recognizer: Optional[KaldiRecognizer] = None
        self._model_path = model_path
        self._is_initialized = False
        self._last_partial = ""

    def initialize(self) -> bool:
        """
        Initialize the Vosk model and recognizer.
        Downloads model if not present.

        Returns:
            True if initialization successful, False otherwise.
        """
        if not VOSK_AVAILABLE:
            logger.error("Vosk not available. Install with: pip install vosk")
            return False

        if self._is_initialized:
            return True

        try:
            # Get model path
            model_path = self._get_model_path()
            if not model_path:
                logger.error("Failed to get model path")
                return False

            # Check if model exists, download if not
            if not os.path.exists(model_path):
                logger.info(f"Model not found at {model_path}, downloading...")
                if not self._download_model(model_path):
                    return False

            # Load model
            logger.info(f"Loading Vosk model from {model_path}")
            self.model = Model(model_path)

            # Create recognizer
            self.recognizer = KaldiRecognizer(self.model, self.sample_rate)
            self.recognizer.SetWords(True)  # Enable word-level timestamps

            self._is_initialized = True
            logger.info("Vosk STT initialized successfully")
            return True

        except Exception as e:
            logger.error(f"Failed to initialize Vosk: {e}")
            return False

    def _get_model_path(self) -> Optional[str]:
        """Get the path to the Vosk model."""
        if self._model_path:
            return self._model_path

        # Default to models directory in server folder
        server_dir = os.path.dirname(os.path.abspath(__file__))
        models_dir = os.path.join(server_dir, "models", "vosk")
        os.makedirs(models_dir, exist_ok=True)

        return os.path.join(models_dir, self.MODEL_NAME)

    def _download_model(self, model_path: str) -> bool:
        """Download and extract the Vosk model."""
        try:
            models_dir = os.path.dirname(model_path)
            zip_path = os.path.join(models_dir, f"{self.MODEL_NAME}.zip")

            # Download
            logger.info(f"Downloading model from {self.MODEL_URL}")
            logger.info("This may take a few minutes (~42MB)...")

            def progress_hook(count, block_size, total_size):
                percent = int(count * block_size * 100 / total_size)
                if count % 100 == 0:
                    logger.info(f"Download progress: {percent}%")

            urllib.request.urlretrieve(self.MODEL_URL, zip_path, progress_hook)
            logger.info("Download complete, extracting...")

            # Extract
            with zipfile.ZipFile(zip_path, 'r') as zip_ref:
                zip_ref.extractall(models_dir)

            # Clean up zip
            os.remove(zip_path)

            logger.info(f"Model extracted to {model_path}")
            return True

        except Exception as e:
            logger.error(f"Failed to download model: {e}")
            return False

    def process_audio(self, audio_data: bytes) -> Optional[TranscriptionResult]:
        """
        Process audio chunk and return transcription result.

        Args:
            audio_data: PCM16 audio data (16-bit signed, little-endian)

        Returns:
            TranscriptionResult with text and is_final flag, or None if no result.
        """
        if not self._is_initialized or not self.recognizer:
            return None

        try:
            # Feed audio to recognizer
            # Returns True if silence detected (end of utterance)
            is_final = self.recognizer.AcceptWaveform(audio_data)

            if is_final:
                # Final result - complete utterance
                result = json.loads(self.recognizer.Result())
                text = result.get("text", "").strip()

                if text:
                    self._last_partial = ""
                    return TranscriptionResult(
                        text=text,
                        is_final=True,
                        confidence=0.9
                    )
            else:
                # Partial result - still speaking
                result = json.loads(self.recognizer.PartialResult())
                text = result.get("partial", "").strip()

                # Only emit if changed
                if text and text != self._last_partial:
                    self._last_partial = text
                    return TranscriptionResult(
                        text=text,
                        is_final=False,
                        confidence=0.7
                    )

            return None

        except Exception as e:
            logger.error(f"Error processing audio: {e}")
            return None

    def get_final_result(self) -> Optional[TranscriptionResult]:
        """
        Get final result and reset recognizer.
        Call this at end of call to flush any remaining audio.

        Returns:
            Final TranscriptionResult or None.
        """
        if not self.recognizer:
            return None

        try:
            result = json.loads(self.recognizer.FinalResult())
            text = result.get("text", "").strip()

            self._last_partial = ""

            if text:
                return TranscriptionResult(
                    text=text,
                    is_final=True,
                    confidence=0.9
                )
            return None

        except Exception as e:
            logger.error(f"Error getting final result: {e}")
            return None

    def reset(self):
        """Reset the recognizer state for a new utterance."""
        if self.recognizer:
            # Re-create recognizer to reset state
            self.recognizer = KaldiRecognizer(self.model, self.sample_rate)
            self.recognizer.SetWords(True)
        self._last_partial = ""

    def dispose(self):
        """Clean up resources."""
        self.recognizer = None
        self.model = None
        self._is_initialized = False


class VoskProcessorPool:
    """
    Pool of Vosk processors for handling multiple concurrent calls.
    Uses a shared model to save memory.
    """

    def __init__(self):
        self._model: Optional[Model] = None
        self._model_path: Optional[str] = None
        self._sample_rate: int = 8000
        self._processors: dict = {}
        self._is_initialized = False

    def initialize(self, model_path: Optional[str] = None, sample_rate: int = 8000) -> bool:
        """
        Initialize the processor pool with a shared model.

        Args:
            model_path: Path to Vosk model directory.
            sample_rate: Audio sample rate.

        Returns:
            True if initialization successful.
        """
        if not VOSK_AVAILABLE:
            logger.warning("Vosk not available - STT disabled")
            return False

        if self._is_initialized:
            return True

        self._sample_rate = sample_rate

        # Create a temporary processor to handle model download/loading
        temp_processor = VoskSTTProcessor(model_path, sample_rate)
        if not temp_processor.initialize():
            return False

        # Store the loaded model for sharing
        self._model = temp_processor.model
        self._model_path = temp_processor._get_model_path()
        self._is_initialized = True

        logger.info("Vosk processor pool initialized")
        return True

    def get_processor(self, call_sid: str) -> Optional['CallSTTProcessor']:
        """
        Get or create an STT processor for a call.

        Args:
            call_sid: Unique call identifier.

        Returns:
            CallSTTProcessor instance or None if not initialized.
        """
        if not self._is_initialized or not self._model:
            return None

        if call_sid not in self._processors:
            processor = CallSTTProcessor(self._model, self._sample_rate)
            self._processors[call_sid] = processor
            logger.info(f"Created STT processor for call: {call_sid}")

        return self._processors[call_sid]

    def release_processor(self, call_sid: str):
        """Release a processor when call ends."""
        if call_sid in self._processors:
            self._processors[call_sid].dispose()
            del self._processors[call_sid]
            logger.info(f"Released STT processor for call: {call_sid}")

    def shutdown_all(self):
        """Shutdown all processors."""
        for call_sid in list(self._processors.keys()):
            self.release_processor(call_sid)
        self._model = None
        self._is_initialized = False
        logger.info("Vosk processor pool shutdown")


class CallSTTProcessor:
    """
    STT processor for a single call.
    Uses a shared model but has its own recognizer state.
    """

    def __init__(self, model: Model, sample_rate: int):
        self.model = model
        self.sample_rate = sample_rate
        self.recognizer = KaldiRecognizer(model, sample_rate)
        self.recognizer.SetWords(True)
        self._last_partial = ""

    def process_audio(self, audio_data: bytes) -> Optional[TranscriptionResult]:
        """Process audio and return transcription result."""
        try:
            is_final = self.recognizer.AcceptWaveform(audio_data)

            if is_final:
                result = json.loads(self.recognizer.Result())
                text = result.get("text", "").strip()

                if text:
                    self._last_partial = ""
                    return TranscriptionResult(
                        text=text,
                        is_final=True,
                        confidence=0.9
                    )
            else:
                result = json.loads(self.recognizer.PartialResult())
                text = result.get("partial", "").strip()

                if text and text != self._last_partial:
                    self._last_partial = text
                    return TranscriptionResult(
                        text=text,
                        is_final=False,
                        confidence=0.7
                    )

            return None

        except Exception as e:
            logger.error(f"STT processing error: {e}")
            return None

    def get_final_result(self) -> Optional[TranscriptionResult]:
        """Get final result and reset."""
        try:
            result = json.loads(self.recognizer.FinalResult())
            text = result.get("text", "").strip()
            self._last_partial = ""

            if text:
                return TranscriptionResult(text=text, is_final=True, confidence=0.9)
            return None
        except Exception:
            return None

    def reset(self):
        """Reset recognizer state."""
        self.recognizer = KaldiRecognizer(self.model, self.sample_rate)
        self.recognizer.SetWords(True)
        self._last_partial = ""

    def dispose(self):
        """Clean up."""
        self.recognizer = None


# Global processor pool
stt_processor_pool = VoskProcessorPool()
