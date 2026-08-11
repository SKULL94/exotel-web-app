"""
Server configuration for VoIP POC WebSocket server.
Handles Exotel stream reception and ai-coustics Sparrow AI processing.
"""

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass
class AudioConfig:
    """Audio stream configuration matching Exotel specifications."""
    sample_rate: int = 8000  # Exotel uses 8kHz
    bit_depth: int = 16
    channels: int = 1  # Mono
    chunk_size: int = 320  # 20ms at 8kHz (160 samples * 2 bytes)
    encoding: str = "linear16"  # PCM 16-bit


@dataclass
class SparrowConfig:
    """ai-coustics Sparrow SDK configuration."""
    model_id: str = "sparrow-s-8khz"   # Model ID for download
    model_path: str = ""                # Local directory to cache models
    enable: bool = True                 # Enable noise cancellation

    def __post_init__(self):
        server_dir = Path(__file__).parent
        if not self.model_path:
            self.model_path = str(server_dir / "models" / "sparrow")


@dataclass
class ServerConfig:
    """WebSocket server configuration."""
    host: str = "0.0.0.0"
    port: int = 8765
    exotel_ws_path: str = "/exotel-stream"
    client_ws_path: str = "/audio-stream"
    health_path: str = "/health"

    # Connection settings
    max_connections: int = 100
    ping_interval: int = 30
    ping_timeout: int = 10

    # Buffer settings
    audio_buffer_size: int = 10  # Number of chunks to buffer


class Config:
    """Main configuration class."""

    def __init__(self):
        self.audio = AudioConfig()
        self.sparrow = SparrowConfig()
        self.server = ServerConfig()

        # Load from environment variables
        self._load_from_env()

    def _load_from_env(self):
        """Load configuration from environment variables."""
        server_dir = Path(__file__).parent

        # Server config
        self.server.host = os.getenv("SERVER_HOST", self.server.host)
        self.server.port = int(os.getenv("SERVER_PORT", self.server.port))

        # Sparrow config
        model_id = os.getenv("AIC_MODEL_ID")
        if model_id:
            self.sparrow.model_id = model_id

        model_path = os.getenv("AIC_MODEL_PATH")
        if model_path:
            p = Path(model_path)
            if not p.is_absolute():
                p = server_dir / model_path
            self.sparrow.model_path = str(p.resolve())

        enable = os.getenv("AIC_ENABLE_NC")
        if enable is not None:
            self.sparrow.enable = enable.lower() == "true"

        # Audio config
        sample_rate = os.getenv("AUDIO_SAMPLE_RATE")
        if sample_rate:
            self.audio.sample_rate = int(sample_rate)


# Global config instance
config = Config()
