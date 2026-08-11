"""
Audio utility functions for format conversion.
Handles mulaw/alaw to PCM conversion for Exotel streams.
Uses proper ITU G.711 decoding algorithms.
"""

import os
import numpy as np
import logging

logger = logging.getLogger(__name__)

# Build proper ITU G.711 mu-law decode table
def _build_mulaw_decode_table():
    """Build mu-law to linear PCM decode table per ITU G.711."""
    table = np.zeros(256, dtype=np.int16)
    for i in range(256):
        # Invert all bits
        mulaw = ~i & 0xFF

        # Extract components
        sign = (mulaw & 0x80)  # Sign bit
        exponent = (mulaw >> 4) & 0x07  # Exponent (3 bits)
        mantissa = mulaw & 0x0F  # Mantissa (4 bits)

        # Decode to linear
        # Formula: ((mantissa << 3) + 0x84) << exponent
        magnitude = ((mantissa << 3) + 0x84) << exponent
        magnitude -= 0x84  # Remove bias

        if sign:
            table[i] = -magnitude
        else:
            table[i] = magnitude

    return table


# Build proper ITU G.711 A-law decode table
def _build_alaw_decode_table():
    """Build A-law to linear PCM decode table per ITU G.711."""
    table = np.zeros(256, dtype=np.int16)
    for i in range(256):
        # Toggle even bits
        alaw = i ^ 0x55

        # Extract components
        sign = alaw & 0x80
        exponent = (alaw >> 4) & 0x07
        mantissa = alaw & 0x0F

        if exponent == 0:
            magnitude = (mantissa << 4) + 8
        else:
            magnitude = ((mantissa << 4) + 0x108) << (exponent - 1)

        if sign:
            table[i] = magnitude
        else:
            table[i] = -magnitude

    return table


# Pre-computed decode tables
MULAW_DECODE_TABLE = _build_mulaw_decode_table()
ALAW_DECODE_TABLE = _build_alaw_decode_table()

# Debug: log first decode to verify
_first_decode_logged = False
_first_format_logged = False


def mulaw_to_pcm16(mulaw_data: bytes) -> bytes:
    """
    Convert mu-law encoded audio to PCM 16-bit.

    Args:
        mulaw_data: Mu-law encoded audio bytes (1 byte per sample).

    Returns:
        PCM 16-bit signed audio bytes (2 bytes per sample, little-endian).
    """
    global _first_decode_logged

    mulaw_array = np.frombuffer(mulaw_data, dtype=np.uint8)
    pcm_array = MULAW_DECODE_TABLE[mulaw_array]

    if not _first_decode_logged and len(mulaw_array) > 0:
        logger.info(f"Mulaw decode sample - Input bytes: {mulaw_array[:10].tolist()}")
        logger.info(f"Mulaw decode sample - Output PCM16: {pcm_array[:10].tolist()}")
        _first_decode_logged = True

    return pcm_array.tobytes()


def alaw_to_pcm16(alaw_data: bytes) -> bytes:
    """
    Convert A-law encoded audio to PCM 16-bit.

    Args:
        alaw_data: A-law encoded audio bytes (1 byte per sample).

    Returns:
        PCM 16-bit signed audio bytes (2 bytes per sample, little-endian).
    """
    alaw_array = np.frombuffer(alaw_data, dtype=np.uint8)
    pcm_array = ALAW_DECODE_TABLE[alaw_array]
    return pcm_array.tobytes()


def pcm16_to_mulaw(pcm_data: bytes) -> bytes:
    """
    Convert PCM 16-bit audio to mu-law encoding.

    Args:
        pcm_data: PCM 16-bit signed audio bytes.

    Returns:
        Mu-law encoded audio bytes.
    """
    pcm_array = np.frombuffer(pcm_data, dtype=np.int16)

    # Clamp and get sign
    sign = np.where(pcm_array < 0, 0x80, 0).astype(np.uint8)
    magnitude = np.abs(pcm_array).astype(np.int32)

    # Add bias
    magnitude = np.clip(magnitude + 0x84, 0, 0x7FFF)

    # Find exponent
    exponent = np.zeros(len(magnitude), dtype=np.uint8)
    for exp in range(7, -1, -1):
        mask = magnitude >= (1 << (exp + 7))
        exponent = np.where(mask & (exponent == 0), exp, exponent)

    # Calculate mantissa
    mantissa = ((magnitude >> (exponent + 3)) & 0x0F).astype(np.uint8)

    # Combine and invert
    mulaw = ~(sign | (exponent << 4) | mantissa) & 0xFF

    return mulaw.astype(np.uint8).tobytes()


def detect_audio_format(audio_data: bytes, log_details: bool = False) -> str:
    """
    Auto-detect audio format from data characteristics.

    Mulaw/Alaw: 8-bit samples, values typically 0x00-0xFF with specific patterns
    Linear16: 16-bit samples, pairs of bytes forming signed integers

    Key insight: 320 bytes at 8kHz for 20ms:
    - If mulaw: 320 samples (1 byte each) = 40ms -> doesn't match 20ms timestamp
    - If linear16: 160 samples (2 bytes each) = 20ms -> matches!
    """
    if len(audio_data) < 10:
        return "linear16"  # Default

    # Check if data looks like little-endian 16-bit PCM
    # In PCM16, every second byte (high byte) should often be 0x00 or 0xFF for quiet audio
    # and the pattern should show typical audio waveform characteristics

    samples = np.frombuffer(audio_data[:min(100, len(audio_data))], dtype=np.int16)
    raw_bytes = np.frombuffer(audio_data[:20], dtype=np.uint8)

    # Check if values are within reasonable PCM16 range for speech
    # Speech typically has values in range -8000 to +8000 for quiet to normal speech
    max_val = np.max(np.abs(samples))
    min_val = np.min(samples)
    mean_val = np.mean(np.abs(samples))

    if log_details:
        logger.info(f"Audio format detection - raw bytes (first 20): {list(raw_bytes)}")
        logger.info(f"Audio format detection - as int16 samples: min={min_val}, max={max_val}, mean={mean_val:.1f}")

    # If max value is small (< 1000), it's likely already PCM16
    # Mulaw decoded incorrectly would produce values near 32000
    if max_val < 5000:
        if log_details:
            logger.info(f"Detected as linear16 (max_val {max_val} < 5000)")
        return "linear16"

    # Check byte pattern - in 16-bit LE, high bytes should have variance
    high_bytes = np.frombuffer(audio_data[1::2][:50], dtype=np.uint8)
    low_bytes = np.frombuffer(audio_data[0::2][:50], dtype=np.uint8)

    # In PCM16 for quiet/normal speech, high byte is often 0x00 or 0xFF
    high_byte_zeros = np.sum((high_bytes == 0) | (high_bytes == 0xFF))
    if high_byte_zeros > len(high_bytes) * 0.3:
        if log_details:
            logger.info(f"Detected as linear16 (high_byte pattern: {high_byte_zeros}/{len(high_bytes)} zeros/FFs)")
        return "linear16"

    if log_details:
        logger.info(f"Detected as mulaw (max_val={max_val}, high_byte_zeros={high_byte_zeros})")
    return "mulaw"


# Environment variable to force a specific encoding (bypass auto-detection)
# Set to "mulaw", "linear16", or "auto" (default)
FORCE_ENCODING = os.getenv("FORCE_AUDIO_ENCODING", "auto").lower()


def detect_and_convert_audio(audio_data: bytes, encoding: str = "audio/x-mulaw") -> bytes:
    """
    Detect audio encoding and convert to PCM 16-bit if needed.

    Args:
        audio_data: Raw audio bytes.
        encoding: Audio encoding type from Exotel metadata.

    Returns:
        PCM 16-bit signed audio bytes (little-endian).
    """
    global _first_format_logged
    encoding_lower = encoding.lower() if encoding else ""

    # Check if we should force a specific encoding
    if FORCE_ENCODING == "mulaw":
        if not _first_format_logged:
            logger.info(f"FORCE_AUDIO_ENCODING=mulaw - forcing mulaw decode")
            _first_format_logged = True
        return mulaw_to_pcm16(audio_data)
    elif FORCE_ENCODING == "linear16":
        if not _first_format_logged:
            logger.info(f"FORCE_AUDIO_ENCODING=linear16 - using raw data as PCM16")
            _first_format_logged = True
        return audio_data

    # Log first frame's format detection with detailed analysis
    if not _first_format_logged and len(audio_data) > 0:
        _first_format_logged = True
        raw_bytes = np.frombuffer(audio_data[:20], dtype=np.uint8)
        samples_as_pcm16 = np.frombuffer(audio_data[:20], dtype=np.int16)

        logger.info(f"=== FIRST FRAME FORMAT ANALYSIS ===")
        logger.info(f"  Header encoding from Exotel: {encoding}")
        logger.info(f"  Data length: {len(audio_data)} bytes")
        logger.info(f"  Raw bytes (first 20): {list(raw_bytes)}")
        logger.info(f"  As PCM16 samples: {samples_as_pcm16.tolist()}")

        # Run detection with detailed logging
        detected = detect_audio_format(audio_data, log_details=True)
        logger.info(f"  Final detection result: {detected}")
        logger.info(f"  FORCE_AUDIO_ENCODING setting: {FORCE_ENCODING}")
        logger.info(f"===================================")

    logger.debug(f"Audio conversion: {len(audio_data)} bytes, encoding: {encoding}")

    # If encoding explicitly specified and not empty/default
    if "linear" in encoding_lower or "pcm" in encoding_lower or "l16" in encoding_lower:
        logger.debug("Encoding is linear16, returning as-is")
        return audio_data
    elif "alaw" in encoding_lower:
        return alaw_to_pcm16(audio_data)
    elif "mulaw" in encoding_lower or "ulaw" in encoding_lower:
        # Even if mulaw specified, verify the data format
        # Exotel may send linear16 despite saying mulaw
        detected = detect_audio_format(audio_data)
        if detected == "linear16":
            logger.info("Data appears to be linear16 despite mulaw encoding header - using raw data")
            return audio_data
        return mulaw_to_pcm16(audio_data)
    else:
        # Unknown encoding - auto-detect from data
        detected = detect_audio_format(audio_data)
        logger.info(f"Unknown encoding '{encoding}', auto-detected as {detected}")
        if detected == "linear16":
            return audio_data
        elif detected == "alaw":
            return alaw_to_pcm16(audio_data)
        else:
            return mulaw_to_pcm16(audio_data)


def get_audio_level(pcm_data: bytes) -> float:
    """
    Calculate RMS audio level from PCM 16-bit data.

    Args:
        pcm_data: PCM 16-bit signed audio bytes.

    Returns:
        RMS level as float (0.0 to 1.0).
    """
    if len(pcm_data) < 2:
        return 0.0

    try:
        samples = np.frombuffer(pcm_data, dtype=np.int16)
        if len(samples) == 0:
            return 0.0

        # Calculate RMS
        rms = np.sqrt(np.mean(samples.astype(np.float64) ** 2))

        # Normalize to 0-1 range (max int16 is 32767)
        return min(1.0, rms / 32767.0)
    except Exception:
        return 0.0
