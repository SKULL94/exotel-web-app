"""
ai-coustics Sparrow SDK integration for real-time audio noise cancellation.
Replaces Krisp Audio SDK. Processes audio streams from Exotel and applies NC.

Sparrow models are optimized for human-to-human voice calls (telephony).
Model used: sparrow-s-8khz (matches Exotel's 8kHz telephony audio).
"""

import logging
import os
import numpy as np
from typing import Optional, Tuple
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

try:
    import aic_sdk as aic
    AIC_AVAILABLE = True
except ImportError:
    AIC_AVAILABLE = False
    aic = None

from config import config

logger = logging.getLogger(__name__)


class ProcessorState(Enum):
    """Processor state enumeration."""
    UNINITIALIZED = "uninitialized"
    INITIALIZING = "initializing"
    READY = "ready"
    PROCESSING = "processing"
    ERROR = "error"
    BYPASSED = "bypassed"


@dataclass
class ProcessingStats:
    """Statistics for audio processing."""
    frames_processed: int = 0
    frames_with_voice: int = 0
    total_noise_reduced_db: float = 0.0
    avg_noise_level: float = 0.0


# RMS threshold for voice activity detection (no built-in VAD in Sparrow)
# Values below this are considered silence/noise-only
# NOTE: Threshold lowered from 200 to 50 because Sparrow's noise cancellation
# can significantly reduce signal amplitude, causing false negatives
VAD_RMS_THRESHOLD = 50
VAD_CONFIDENCE_SCALE = 1500.0  # RMS value that maps to confidence=1.0

# Post-processing gain to compensate for Sparrow's aggressive noise cancellation.
# Sparrow can significantly reduce signal amplitude, making voices sound quiet.
# Default 2.0 = 6dB boost. Set to 1.0 to disable gain compensation.
POST_PROCESSING_GAIN = float(os.getenv("SPARROW_POST_GAIN", "2.0"))


class SparrowProcessor:
    """
    ai-coustics Sparrow processor for noise cancellation.
    Handles real-time audio stream processing from Exotel.

    Exotel sends PCM16 mono at 8kHz. The Sparrow SDK expects float32
    arrays shaped (channels, frames). This class handles the conversion
    and frame-size buffering transparently.
    """

    def __init__(self):
        self.state = ProcessorState.UNINITIALIZED
        self.stats = ProcessingStats()
        self._processor = None
        self._model = None
        self._bypass_mode = False
        self._num_frames = 0        # Fixed frame size required by the model
        self._sample_buffer = np.array([], dtype=np.int16)  # Accumulation buffer

    def initialize(
        self,
        model_id: str = "sparrow-s-8khz",
        model_dir: Optional[str] = None,
        license_key: Optional[str] = None,
        sample_rate: int = 8000,
    ) -> bool:
        """
        Initialize the Sparrow processor.

        Downloads the model on first run (cached after that). Creates an
        aic.Processor instance bound to this call session.

        Args:
            model_id:    ai-coustics model ID, e.g. "sparrow-s-8khz".
            model_dir:   Directory to store downloaded models.
            license_key: AIC_SDK_LICENSE key. Falls back to env var.
            sample_rate: Audio sample rate (must match model, default 8000).

        Returns:
            True if initialization succeeded (or bypass mode activated).
        """
        if not AIC_AVAILABLE:
            logger.warning("aic-sdk not installed. Running in bypass mode (no noise cancellation).")
            logger.warning("Install with: pip install aic-sdk")
            self.state = ProcessorState.BYPASSED
            self._bypass_mode = True
            return True

        license_key = license_key or os.getenv("AIC_SDK_LICENSE", "")
        if not license_key:
            logger.warning("No AIC_SDK_LICENSE key provided. Running in bypass mode.")
            logger.warning("Set AIC_SDK_LICENSE environment variable to enable noise cancellation.")
            self.state = ProcessorState.BYPASSED
            self._bypass_mode = True
            return True

        self.state = ProcessorState.INITIALIZING

        # Resolve model directory
        if model_dir is None:
            model_dir = str(Path(__file__).parent / "models" / "sparrow")
        Path(model_dir).mkdir(parents=True, exist_ok=True)

        try:
            logger.info(f"Downloading/loading Sparrow model: {model_id}")
            model_path = aic.Model.download(model_id, model_dir)
            self._model = aic.Model.from_file(model_path)

            # num_channels=1 for Exotel mono telephony audio
            proc_config = aic.ProcessorConfig.optimal(self._model, num_channels=1)
            self._num_frames = proc_config.num_frames
            self._sample_buffer = np.array([], dtype=np.int16)

            self._processor = aic.Processor(self._model, license_key, proc_config)

            self.state = ProcessorState.READY
            logger.info(f"Sparrow processor initialized: model={model_id}, "
                        f"num_frames={self._num_frames}, sample_rate={sample_rate}Hz")
            # Log expected buffering behavior
            # Exotel sends 160 samples (320 bytes) per 20ms at 8kHz
            chunks_needed = (self._num_frames + 159) // 160
            logger.info(f"Sparrow requires {self._num_frames} samples per frame. "
                        f"Will need ~{chunks_needed} Exotel chunks before processing.")
            logger.info(f"Post-processing gain: {POST_PROCESSING_GAIN}x "
                        f"({20 * np.log10(POST_PROCESSING_GAIN):.1f} dB)")
            return True

        except Exception as e:
            logger.error(f"Failed to initialize Sparrow processor: {e}")
            logger.warning("Running in bypass mode (no noise cancellation).")
            self.state = ProcessorState.BYPASSED
            self._bypass_mode = True
            return False

    def process_audio(self, audio_data: bytes) -> Tuple[bytes, bool, float]:
        """
        Process a chunk of PCM16 audio through Sparrow noise cancellation.

        Buffers incoming samples and processes in fixed-size batches matching
        the model's required frame size. Returns processed audio from all
        complete frames available.

        Args:
            audio_data: Raw PCM16 bytes (int16, mono, 8kHz from Exotel).

        Returns:
            Tuple of (processed_audio_bytes, has_voice, vad_confidence).
            processed_audio_bytes may be empty if buffer hasn't filled yet.
        """
        if self._bypass_mode or self.state == ProcessorState.BYPASSED:
            return audio_data, True, 1.0

        if self.state != ProcessorState.READY:
            logger.warning(f"Sparrow processor not ready: {self.state}")
            return audio_data, True, 1.0

        if not audio_data:
            return b"", True, 1.0

        try:
            self.state = ProcessorState.PROCESSING

            # Accumulate incoming int16 samples
            new_samples = np.frombuffer(audio_data, dtype=np.int16)
            self._sample_buffer = np.concatenate([self._sample_buffer, new_samples])

            output_chunks = []
            has_voice = True
            vad_confidence = 1.0

            # Process all complete frames available in the buffer
            while len(self._sample_buffer) >= self._num_frames:
                frame_int16 = self._sample_buffer[:self._num_frames]
                self._sample_buffer = self._sample_buffer[self._num_frames:]

                # Convert int16 → float32 normalized to [-1.0, 1.0], shape (1, num_frames)
                float_frame = (frame_int16.astype(np.float32) / 32768.0).reshape(1, -1)

                # Apply Sparrow noise cancellation
                processed_float = self._processor.process(float_frame)  # (1, num_frames)

                # Apply post-processing gain to compensate for aggressive NC
                if POST_PROCESSING_GAIN != 1.0:
                    processed_float = processed_float * POST_PROCESSING_GAIN

                # Convert float32 → int16, shape (num_frames,)
                # Clip to valid int16 range to prevent overflow
                processed_int16 = (
                    (processed_float[0] * 32767.0)
                    .clip(-32767.0, 32767.0)
                    .astype(np.int16)
                )
                output_chunks.append(processed_int16)

                # Calculate RMS before and after processing for diagnostics
                input_rms = float(np.sqrt(np.mean(frame_int16.astype(np.float32) ** 2)))
                output_rms = float(np.sqrt(np.mean(processed_int16.astype(np.float32) ** 2)))

                # Log first few frames to help diagnose issues
                if self.stats.frames_processed < 5:
                    logger.info(f"Sparrow frame {self.stats.frames_processed}: "
                               f"input_rms={input_rms:.0f}, output_rms={output_rms:.0f}, "
                               f"gain={POST_PROCESSING_GAIN}x")

                # RMS-based voice activity detection (on output)
                vad_confidence = min(1.0, output_rms / VAD_CONFIDENCE_SCALE)
                has_voice = output_rms > VAD_RMS_THRESHOLD

                self.stats.frames_processed += 1
                if has_voice:
                    self.stats.frames_with_voice += 1

            self.state = ProcessorState.READY

            if output_chunks:
                return np.concatenate(output_chunks).tobytes(), has_voice, vad_confidence
            else:
                # Buffer not yet full — return empty (will output on next call)
                # Log buffering status at INFO level so we can see it
                buffer_pct = (len(self._sample_buffer) / self._num_frames * 100) if self._num_frames > 0 else 0
                if self.stats.frames_processed == 0 or len(self._sample_buffer) % 50 == 0:
                    logger.info(f"Sparrow buffering: {len(self._sample_buffer)}/{self._num_frames} samples ({buffer_pct:.0f}%)")
                return b"", has_voice, vad_confidence

        except Exception as e:
            logger.error(f"Error processing audio through Sparrow: {e}")
            self.state = ProcessorState.READY
            return audio_data, True, 1.0

    def get_stats(self) -> dict:
        """Get processing statistics."""
        voice_ratio = (
            self.stats.frames_with_voice / self.stats.frames_processed
            if self.stats.frames_processed > 0 else 0.0
        )
        return {
            "state": self.state.value,
            "bypass_mode": self._bypass_mode,
            "frames_processed": self.stats.frames_processed,
            "frames_with_voice": self.stats.frames_with_voice,
            "voice_activity_ratio": voice_ratio,
            "frame_size": self._num_frames,
            "buffer_samples": len(self._sample_buffer),
        }

    def reset_stats(self):
        """Reset processing statistics."""
        self.stats = ProcessingStats()

    def shutdown(self):
        """Clean up processor resources."""
        try:
            self._processor = None
            self._model = None
            self._sample_buffer = np.array([], dtype=np.int16)
            self.state = ProcessorState.UNINITIALIZED
            logger.info("Sparrow processor shut down")
        except Exception as e:
            logger.error(f"Error during Sparrow processor shutdown: {e}")


class SparrowProcessorPool:
    """
    Pool of Sparrow processors — one per active call.
    Mirrors the KrispProcessorPool interface so main.py needs minimal changes.
    """

    def __init__(self, max_processors: int = 10):
        self.max_processors = max_processors
        self._processors: dict[str, SparrowProcessor] = {}
        self._model_id: str = "sparrow-s-8khz"
        self._model_path: Optional[str] = None   # resolved model dir
        self._sample_rate: int = 8000
        self._license_key: str = ""

    def initialize(
        self,
        model_id: Optional[str] = None,
        model_path: Optional[str] = None,
        sample_rate: int = 8000,
        # Accept (and ignore) legacy Krisp keyword args for drop-in compatibility
        **kwargs,
    ) -> bool:
        """Initialize the pool — store config for per-call processors."""
        self._model_id = model_id or os.getenv("AIC_MODEL_ID", "sparrow-s-8khz")
        self._sample_rate = sample_rate
        self._license_key = os.getenv("AIC_SDK_LICENSE", "")

        if model_path:
            self._model_path = model_path
        else:
            env_path = os.getenv("AIC_MODEL_PATH")
            if env_path:
                p = Path(env_path)
                if not p.is_absolute():
                    p = Path(__file__).parent / env_path
                self._model_path = str(p.resolve())
            else:
                self._model_path = str(Path(__file__).parent / "models" / "sparrow")

        logger.info("Sparrow processor pool initialized")
        logger.info(f"  Model ID:    {self._model_id}")
        logger.info(f"  Model dir:   {self._model_path}")
        logger.info(f"  Sample rate: {self._sample_rate}Hz")
        logger.info(f"  SDK available: {AIC_AVAILABLE}")
        return True

    def get_processor(self, call_sid: str) -> SparrowProcessor:
        """Get or create a Sparrow processor for a specific call."""
        if call_sid not in self._processors:
            if len(self._processors) >= self.max_processors:
                # Evict the oldest processor
                oldest_sid = next(iter(self._processors))
                self.release_processor(oldest_sid)

            processor = SparrowProcessor()
            processor.initialize(
                model_id=self._model_id,
                model_dir=self._model_path,
                license_key=self._license_key,
                sample_rate=self._sample_rate,
            )
            self._processors[call_sid] = processor
            logger.info(f"Created Sparrow processor for call: {call_sid}")

        return self._processors[call_sid]

    def release_processor(self, call_sid: str):
        """Release the processor for a completed call."""
        if call_sid in self._processors:
            self._processors[call_sid].shutdown()
            del self._processors[call_sid]
            logger.info(f"Released Sparrow processor for call: {call_sid}")

    def shutdown_all(self):
        """Shutdown all processors in the pool."""
        for call_sid in list(self._processors.keys()):
            self.release_processor(call_sid)
        logger.info("All Sparrow processors shut down")


# Global processor pool — imported by main.py
processor_pool = SparrowProcessorPool()
