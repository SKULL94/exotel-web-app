"""
Krisp Audio SDK integration for real-time audio noise cancellation.
Processes audio streams from Exotel and applies NC/VAD.
"""

import logging
import struct
import numpy as np
from typing import Optional, Tuple, List
from dataclasses import dataclass
from enum import Enum
from pathlib import Path

try:
    import krisp_audio
    KRISP_AVAILABLE = True
except ImportError:
    KRISP_AVAILABLE = False
    krisp_audio = None

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


def _licensing_error_callback(error, error_message):
    """Callback for Krisp licensing errors."""
    logger.error(f"Krisp Licensing Error: {error} - {error_message}")


def _log_callback(log_message, log_level):
    """Callback for Krisp SDK logging."""
    logger.debug(f"[Krisp {log_level}] {log_message}")


# Global initialization flag
_krisp_initialized = False


def initialize_krisp_global(license_key: Optional[str] = None):
    """Initialize Krisp SDK globally (call once at startup)."""
    global _krisp_initialized
    import os

    if not KRISP_AVAILABLE:
        logger.warning("Krisp Audio SDK not available")
        return False

    if _krisp_initialized:
        return True

    # Get license key from parameter or environment
    license_key = license_key or os.getenv("KRISP_LICENSE_KEY", "")

    if not license_key:
        logger.warning("No Krisp license key provided. Set KRISP_LICENSE_KEY environment variable.")
        logger.warning("Server will run in bypass mode (no noise cancellation).")
        return False

    try:
        # globalInit signature: (workingPath, licenseKey, licenseCallback, logCallback, logLevel)
        krisp_audio.globalInit(
            "",  # workingPath
            license_key,  # licenseKey
            _licensing_error_callback,  # licenseCallback
            _log_callback,  # logCallback
            krisp_audio.LogLevel.Warn  # logLevel
        )

        version = krisp_audio.getVersion()
        logger.info(f"Krisp Audio SDK initialized: v{version.major}.{version.minor}.{version.patch}")
        _krisp_initialized = True
        return True

    except Exception as e:
        logger.error(f"Failed to initialize Krisp SDK: {e}")
        logger.warning("Server will run in bypass mode (no noise cancellation).")
        return False


def shutdown_krisp_global():
    """Shutdown Krisp SDK globally (call once at shutdown)."""
    global _krisp_initialized

    if KRISP_AVAILABLE and _krisp_initialized:
        try:
            krisp_audio.globalDestroy()
            _krisp_initialized = False
            logger.info("Krisp Audio SDK shutdown complete")
        except Exception as e:
            logger.error(f"Error shutting down Krisp SDK: {e}")


class KrispProcessor:
    """
    Krisp Audio processor for noise cancellation and VAD.
    Handles real-time audio stream processing from Exotel.
    """

    # Sample rate mapping
    SAMPLE_RATES = {
        8000: "Sr8000Hz",
        16000: "Sr16000Hz",
        24000: "Sr24000Hz",
        32000: "Sr32000Hz",
        44100: "Sr44100Hz",
        48000: "Sr48000Hz"
    }

    # Frame duration mapping
    FRAME_DURATIONS = {
        10: "Fd10ms",
        15: "Fd15ms",
        20: "Fd20ms",
        30: "Fd30ms",
        32: "Fd32ms"
    }

    def __init__(self):
        self.state = ProcessorState.UNINITIALIZED
        self.stats = ProcessingStats()
        self._nc_session = None
        self._vad_session = None
        self._bypass_mode = False
        self._frame_size = 0  # Samples per frame
        self._suppression_level = 100  # 0-100%

    def _get_sample_rate(self, rate: int):
        """Get Krisp sample rate enum."""
        if rate not in self.SAMPLE_RATES:
            raise ValueError(f"Unsupported sample rate: {rate}")
        return getattr(krisp_audio.SamplingRate, self.SAMPLE_RATES[rate])

    def _get_frame_duration(self, duration_ms: int):
        """Get Krisp frame duration enum."""
        if duration_ms not in self.FRAME_DURATIONS:
            raise ValueError(f"Unsupported frame duration: {duration_ms}")
        return getattr(krisp_audio.FrameDuration, self.FRAME_DURATIONS[duration_ms])

    def initialize(
        self,
        nc_model_path: Optional[str] = None,
        vad_model_path: Optional[str] = None,
        sample_rate: int = 8000,
        frame_duration_ms: int = 10,
        suppression_level: int = 100
    ) -> bool:
        """
        Initialize Krisp processor with NC and/or VAD sessions.

        Args:
            nc_model_path: Path to noise cancellation .kef model file.
            vad_model_path: Path to VAD .kef model file.
            sample_rate: Audio sample rate (default 8000 for telephony).
            frame_duration_ms: Frame duration in ms (10, 15, 20, 30, 32).
            suppression_level: Noise suppression level 0-100%.

        Returns:
            True if initialization successful.
        """
        if not KRISP_AVAILABLE:
            logger.warning("Krisp Audio SDK not available. Running in bypass mode.")
            self.state = ProcessorState.BYPASSED
            self._bypass_mode = True
            return True

        # Ensure global initialization
        if not _krisp_initialized:
            if not initialize_krisp_global():
                self.state = ProcessorState.BYPASSED
                self._bypass_mode = True
                return True

        self.state = ProcessorState.INITIALIZING
        self._suppression_level = suppression_level
        self._frame_size = int(sample_rate * frame_duration_ms / 1000)

        # Use default model paths if not provided
        models_dir = Path(__file__).parent / "models" / "krisp-viva-models-9.11"

        if nc_model_path is None:
            nc_model_path = str(models_dir / "krisp-viva-tel-v2.kef")

        if vad_model_path is None:
            vad_model_path = str(models_dir / "krisp-viva-vad-v2.kef")

        try:
            # Create NC session if model exists
            if nc_model_path and Path(nc_model_path).exists():
                logger.info(f"Creating NC session with model: {nc_model_path}")

                model_info = krisp_audio.ModelInfo()
                model_info.path = nc_model_path

                nc_cfg = krisp_audio.NcSessionConfig()
                nc_cfg.inputSampleRate = self._get_sample_rate(sample_rate)
                nc_cfg.inputFrameDuration = self._get_frame_duration(frame_duration_ms)
                nc_cfg.outputSampleRate = nc_cfg.inputSampleRate
                nc_cfg.modelInfo = model_info

                # Use Int16 for PCM 16-bit audio (Exotel format)
                self._nc_session = krisp_audio.NcInt16.create(nc_cfg)
                logger.info("NC session created successfully")

            # Create VAD session if model exists
            if vad_model_path and Path(vad_model_path).exists():
                logger.info(f"Creating VAD session with model: {vad_model_path}")

                model_info = krisp_audio.ModelInfo()
                model_info.path = vad_model_path

                vad_cfg = krisp_audio.VadSessionConfig()
                vad_cfg.inputSampleRate = self._get_sample_rate(sample_rate)
                vad_cfg.inputFrameDuration = self._get_frame_duration(frame_duration_ms)
                vad_cfg.modelInfo = model_info

                self._vad_session = krisp_audio.VadInt16.create(vad_cfg)
                logger.info("VAD session created successfully")

            if not self._nc_session and not self._vad_session:
                logger.warning("No Krisp sessions created. Running in bypass mode.")
                self.state = ProcessorState.BYPASSED
                self._bypass_mode = True
            else:
                self.state = ProcessorState.READY
                logger.info("Krisp processor initialized successfully")

            return True

        except Exception as e:
            logger.error(f"Failed to initialize Krisp processor: {e}")
            self.state = ProcessorState.ERROR
            self._bypass_mode = True
            return False

    def process_audio(self, audio_data: bytes) -> Tuple[bytes, bool, float]:
        """
        Process audio data through Krisp noise cancellation.

        Args:
            audio_data: Raw PCM audio bytes (16-bit signed, mono).

        Returns:
            Tuple of (processed_audio_bytes, has_voice, vad_confidence).
        """
        if self._bypass_mode or self.state == ProcessorState.BYPASSED:
            return audio_data, True, 1.0

        if self.state != ProcessorState.READY:
            logger.warning(f"Processor not ready: {self.state}")
            return audio_data, True, 1.0

        try:
            self.state = ProcessorState.PROCESSING

            # Convert bytes to numpy int16 array
            samples = np.frombuffer(audio_data, dtype=np.int16)

            processed_chunks = []
            has_voice = True
            vad_confidence = 1.0

            # Process in frames
            for i in range(0, len(samples), self._frame_size):
                frame = samples[i:i + self._frame_size]

                # Pad last frame if needed
                if len(frame) < self._frame_size:
                    frame = np.pad(frame, (0, self._frame_size - len(frame)))

                # Apply noise cancellation
                if self._nc_session:
                    processed_frame = self._nc_session.process(frame, self._suppression_level)
                else:
                    processed_frame = frame

                # Check voice activity
                if self._vad_session:
                    vad_result = self._vad_session.process(frame)
                    # VAD returns confidence value, typically > 0.5 means voice
                    has_voice = vad_result > 0.5
                    vad_confidence = float(vad_result)

                processed_chunks.append(processed_frame)
                self.stats.frames_processed += 1
                if has_voice:
                    self.stats.frames_with_voice += 1

            # Concatenate processed frames
            if processed_chunks:
                processed_samples = np.concatenate(processed_chunks)
                processed_bytes = processed_samples.astype(np.int16).tobytes()
            else:
                processed_bytes = audio_data

            self.state = ProcessorState.READY
            return processed_bytes, has_voice, vad_confidence

        except Exception as e:
            logger.error(f"Error processing audio: {e}")
            self.state = ProcessorState.READY
            return audio_data, True, 1.0

    def process_frame(self, frame: np.ndarray) -> Tuple[np.ndarray, bool, float]:
        """
        Process a single audio frame (for streaming).

        Args:
            frame: Numpy array of int16 samples (single frame).

        Returns:
            Tuple of (processed_frame, has_voice, vad_confidence).
        """
        if self._bypass_mode or self.state != ProcessorState.READY:
            return frame, True, 1.0

        try:
            # Ensure correct frame size
            if len(frame) != self._frame_size:
                if len(frame) < self._frame_size:
                    frame = np.pad(frame, (0, self._frame_size - len(frame)))
                else:
                    frame = frame[:self._frame_size]

            # Apply NC
            if self._nc_session:
                processed_frame = self._nc_session.process(frame, self._suppression_level)
            else:
                processed_frame = frame

            # Check VAD
            has_voice = True
            vad_confidence = 1.0
            if self._vad_session:
                vad_result = self._vad_session.process(frame)
                has_voice = vad_result > 0.5
                vad_confidence = float(vad_result)

            self.stats.frames_processed += 1
            if has_voice:
                self.stats.frames_with_voice += 1

            return processed_frame, has_voice, vad_confidence

        except Exception as e:
            logger.error(f"Error processing frame: {e}")
            return frame, True, 1.0

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
            "frame_size": self._frame_size,
            "suppression_level": self._suppression_level
        }

    def reset_stats(self):
        """Reset processing statistics."""
        self.stats = ProcessingStats()

    def set_suppression_level(self, level: int):
        """Set noise suppression level (0-100)."""
        self._suppression_level = max(0, min(100, level))

    def shutdown(self):
        """Clean up session resources."""
        try:
            self._nc_session = None
            self._vad_session = None
            self.state = ProcessorState.UNINITIALIZED
            logger.info("Krisp processor session closed")
        except Exception as e:
            logger.error(f"Error during shutdown: {e}")


class KrispProcessorPool:
    """
    Pool of Krisp processors for handling multiple concurrent calls.
    Each call gets its own processor instance.
    """

    def __init__(self, max_processors: int = 10):
        self.max_processors = max_processors
        self._processors: dict[str, KrispProcessor] = {}
        self._nc_model_path: Optional[str] = None
        self._vad_model_path: Optional[str] = None
        self._sample_rate: int = 8000
        self._frame_duration_ms: int = 10

    def initialize(
        self,
        nc_model_path: Optional[str] = None,
        vad_model_path: Optional[str] = None,
        sample_rate: int = 8000,
        frame_duration_ms: int = 10
    ) -> bool:
        """Initialize the processor pool with model paths."""
        # Initialize Krisp globally
        initialize_krisp_global()

        # Store config for new processors
        models_dir = Path(__file__).parent / "models" / "krisp-viva-models-9.11"

        self._nc_model_path = nc_model_path or str(models_dir / "krisp-viva-tel-v2.kef")
        self._vad_model_path = vad_model_path or str(models_dir / "krisp-viva-vad-v2.kef")
        self._sample_rate = sample_rate
        self._frame_duration_ms = frame_duration_ms

        logger.info(f"Krisp processor pool initialized")
        logger.info(f"  NC Model: {self._nc_model_path}")
        logger.info(f"  VAD Model: {self._vad_model_path}")
        logger.info(f"  Sample Rate: {self._sample_rate}Hz")
        logger.info(f"  Frame Duration: {self._frame_duration_ms}ms")

        return True

    def get_processor(self, call_sid: str) -> KrispProcessor:
        """
        Get or create a processor for a specific call.

        Args:
            call_sid: Unique call session identifier.

        Returns:
            KrispProcessor instance for the call.
        """
        if call_sid not in self._processors:
            if len(self._processors) >= self.max_processors:
                # Remove oldest processor
                oldest_sid = next(iter(self._processors))
                self.release_processor(oldest_sid)

            processor = KrispProcessor()
            processor.initialize(
                nc_model_path=self._nc_model_path,
                vad_model_path=self._vad_model_path,
                sample_rate=self._sample_rate,
                frame_duration_ms=self._frame_duration_ms
            )
            self._processors[call_sid] = processor
            logger.info(f"Created processor for call: {call_sid}")

        return self._processors[call_sid]

    def release_processor(self, call_sid: str):
        """Release processor for a completed call."""
        if call_sid in self._processors:
            self._processors[call_sid].shutdown()
            del self._processors[call_sid]
            logger.info(f"Released processor for call: {call_sid}")

    def shutdown_all(self):
        """Shutdown all processors in the pool."""
        for call_sid in list(self._processors.keys()):
            self.release_processor(call_sid)

        # Shutdown global Krisp
        shutdown_krisp_global()
        logger.info("All Krisp processors shut down")


# Global processor pool instance
processor_pool = KrispProcessorPool()
