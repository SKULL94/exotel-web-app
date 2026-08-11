"""
FastAPI WebSocket server for VoIP POC.
Receives audio streams from Exotel and processes through Krisp AI.
"""

import asyncio
import json
import logging
import base64
import wave
import os
from datetime import datetime
from typing import Dict, Set, Optional
from contextlib import asynccontextmanager
from dataclasses import dataclass, field

# Load environment variables from .env file
from dotenv import load_dotenv
load_dotenv()

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Request, Form
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import uvicorn

from config import config
from sparrow_processor import processor_pool, SparrowProcessor
from audio_utils import detect_and_convert_audio, get_audio_level

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


# Create recordings directory
RECORDINGS_DIR = os.path.join(os.path.dirname(__file__), "recordings")
os.makedirs(RECORDINGS_DIR, exist_ok=True)

# Enable/disable audio file saving for debugging
SAVE_AUDIO_FILES = os.getenv("SAVE_AUDIO_FILES", "true").lower() == "true"


@dataclass
class CallSession:
    """Represents an active call session."""
    call_sid: str
    exotel_ws: Optional[WebSocket] = None
    client_ws: Optional[WebSocket] = None
    processor: Optional[SparrowProcessor] = None
    is_active: bool = True
    audio_buffer: list = field(default_factory=list)
    metadata: dict = field(default_factory=dict)
    # Audio file handles for saving
    original_file: Optional[object] = None  # Raw binary file for original mulaw
    original_path: Optional[str] = None
    raw_audio_file: Optional[wave.Wave_write] = None
    processed_audio_file: Optional[wave.Wave_write] = None

    def init_audio_files(self):
        """Initialize WAV files for saving audio."""
        if not SAVE_AUDIO_FILES:
            return

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

        # Original Exotel bytes (mulaw, before conversion) - saved as raw binary
        self.original_path = os.path.join(RECORDINGS_DIR, f"{self.call_sid}_{timestamp}_original.raw")
        self.original_file = open(self.original_path, 'wb')

        # Raw audio from Exotel (after mulaw->PCM16 conversion, before Krisp)
        raw_path = os.path.join(RECORDINGS_DIR, f"{self.call_sid}_{timestamp}_raw.wav")
        self.raw_audio_file = wave.open(raw_path, 'wb')
        self.raw_audio_file.setnchannels(1)
        self.raw_audio_file.setsampwidth(2)  # 16-bit PCM
        self.raw_audio_file.setframerate(8000)

        # Processed audio (after Krisp)
        processed_path = os.path.join(RECORDINGS_DIR, f"{self.call_sid}_{timestamp}_processed.wav")
        self.processed_audio_file = wave.open(processed_path, 'wb')
        self.processed_audio_file.setnchannels(1)
        self.processed_audio_file.setsampwidth(2)  # 16-bit PCM
        self.processed_audio_file.setframerate(8000)

        logger.info(f"Saving audio files to: {RECORDINGS_DIR}")
        logger.info(f"  Original (mulaw): {self.original_path}")
        logger.info(f"  Raw PCM: {raw_path}")
        logger.info(f"  Processed: {processed_path}")

    def close_audio_files(self):
        """Close audio files."""
        if hasattr(self, 'original_file') and self.original_file:
            try:
                self.original_file.close()
                logger.info(f"Original mulaw saved to: {self.original_path}")
            except Exception:
                pass
            self.original_file = None

        if self.raw_audio_file:
            try:
                self.raw_audio_file.close()
            except Exception:
                pass
            self.raw_audio_file = None

        if self.processed_audio_file:
            try:
                self.processed_audio_file.close()
            except Exception:
                pass
            self.processed_audio_file = None


class ConnectionManager:
    """Manages WebSocket connections for Exotel and clients."""

    def __init__(self):
        self.active_sessions: Dict[str, CallSession] = {}
        self.pending_clients: Dict[str, Set[WebSocket]] = {}

    async def connect_exotel(self, websocket: WebSocket, call_sid: str) -> CallSession:
        """Register an Exotel stream connection."""
        await websocket.accept()

        if call_sid in self.active_sessions:
            session = self.active_sessions[call_sid]
            session.exotel_ws = websocket
        else:
            session = CallSession(
                call_sid=call_sid,
                exotel_ws=websocket,
                processor=processor_pool.get_processor(call_sid)
            )
            self.active_sessions[call_sid] = session

        # Connect any pending clients
        # First try exact match
        if call_sid in self.pending_clients:
            for client_ws in self.pending_clients[call_sid]:
                session.client_ws = client_ws
            del self.pending_clients[call_sid]
            logger.info(f"Exotel connected for call: {call_sid} (matched pending client by SID)")
        # If call_sid is "unknown" or no exact match, and there are pending clients, use the first one
        elif len(self.pending_clients) > 0:
            pending_sid = list(self.pending_clients.keys())[0]
            for client_ws in self.pending_clients[pending_sid]:
                session.client_ws = client_ws
            del self.pending_clients[pending_sid]
            logger.info(f"Exotel connected for call: {call_sid}, auto-matched to pending client: {pending_sid}")
        else:
            logger.info(f"Exotel connected for call: {call_sid} (no pending clients)")
        return session

    async def connect_client(self, websocket: WebSocket, call_sid: str) -> Optional[CallSession]:
        """Register a client connection for receiving processed audio."""
        # Note: websocket.accept() should be called by the endpoint, not here

        if call_sid in self.active_sessions:
            session = self.active_sessions[call_sid]
            session.client_ws = websocket
            logger.info(f"Client connected to existing call: {call_sid}")
            return session
        else:
            # Call SID might not match exactly (e.g., server has "unknown")
            # If there's exactly one active session without a client, use it
            sessions_without_client = [
                (sid, sess) for sid, sess in self.active_sessions.items()
                if sess.client_ws is None and sess.is_active
            ]

            if len(sessions_without_client) == 1:
                actual_sid, session = sessions_without_client[0]
                session.client_ws = websocket
                logger.info(f"Client connected to active session (requested: {call_sid}, actual: {actual_sid})")
                return session

            # Store as pending client
            if call_sid not in self.pending_clients:
                self.pending_clients[call_sid] = set()
            self.pending_clients[call_sid].add(websocket)
            logger.info(f"Client waiting for call: {call_sid} (active sessions: {list(self.active_sessions.keys())})")
            return None

    async def disconnect_exotel(self, call_sid: str):
        """Handle Exotel disconnection."""
        if call_sid in self.active_sessions:
            session = self.active_sessions[call_sid]
            session.exotel_ws = None
            session.is_active = False

            # Notify client if connected
            if session.client_ws:
                try:
                    await session.client_ws.send_json({
                        "event": "stream_end",
                        "call_sid": call_sid
                    })
                except Exception:
                    pass

            # Cleanup after short delay to allow final messages
            await asyncio.sleep(1)
            await self.cleanup_session(call_sid)

            logger.info(f"Exotel disconnected for call: {call_sid}")

    async def disconnect_client(self, call_sid: str, websocket: WebSocket):
        """Handle client disconnection."""
        if call_sid in self.active_sessions:
            session = self.active_sessions[call_sid]
            if session.client_ws == websocket:
                session.client_ws = None
                logger.info(f"Client disconnected from call: {call_sid}")

        if call_sid in self.pending_clients:
            self.pending_clients[call_sid].discard(websocket)

    async def cleanup_session(self, call_sid: str):
        """Clean up a call session."""
        if call_sid in self.active_sessions:
            session = self.active_sessions[call_sid]
            session.close_audio_files()  # Close and save audio files
            processor_pool.release_processor(call_sid)
            del self.active_sessions[call_sid]
            logger.info(f"Session cleaned up: {call_sid}")

    async def broadcast_to_client(self, call_sid: str, data: dict):
        """Send data to the connected client."""
        if call_sid in self.active_sessions:
            session = self.active_sessions[call_sid]
            if session.client_ws and session.is_active:
                try:
                    await session.client_ws.send_json(data)
                except Exception as e:
                    logger.warning(f"Client disconnected during broadcast: {e}")
                    session.client_ws = None

    async def send_audio_to_client(self, call_sid: str, audio_data: bytes, metadata: dict = None):
        """Send processed audio to client."""
        if call_sid in self.active_sessions:
            session = self.active_sessions[call_sid]
            if session.client_ws and session.is_active:
                try:
                    # Send as binary with optional metadata header
                    message = {
                        "event": "audio",
                        "call_sid": call_sid,
                        "audio": base64.b64encode(audio_data).decode('utf-8'),
                        "metadata": metadata or {}
                    }
                    await session.client_ws.send_json(message)
                except Exception as e:
                    # Client disconnected - clear reference to prevent repeated errors
                    logger.warning(f"Client disconnected during send, clearing reference: {e}")
                    session.client_ws = None

    async def send_transcript_to_client(self, call_sid: str, text: str, is_final: bool, speaker: str = None):
        """Send transcript to client for real-time display."""
        if call_sid in self.active_sessions:
            session = self.active_sessions[call_sid]
            if session.client_ws and session.is_active:
                try:
                    message = {
                        "event": "transcript",
                        "call_sid": call_sid,
                        "text": text,
                        "is_final": is_final,
                        "speaker": speaker,
                        "language": "hi",
                        "timestamp": datetime.now().isoformat()
                    }
                    await session.client_ws.send_json(message)
                except Exception as e:
                    logger.warning(f"Client disconnected during transcript send: {e}")
                    session.client_ws = None


# Global connection manager
manager = ConnectionManager()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    # Startup
    logger.info("Starting VoIP WebSocket server...")
    processor_pool.initialize(
        model_id=config.sparrow.model_id,
        model_path=config.sparrow.model_path,
        sample_rate=config.audio.sample_rate,
    )

    logger.info(f"Server listening on {config.server.host}:{config.server.port}")

    yield

    # Shutdown
    logger.info("Shutting down...")
    processor_pool.shutdown_all()


# Create FastAPI app
app = FastAPI(
    title="VoIP POC WebSocket Server",
    description="Bridges Exotel audio streams with ai-coustics Sparrow noise cancellation",
    version="1.0.0",
    lifespan=lifespan
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health")
async def health_check():
    """Health check endpoint."""
    return {
        "status": "healthy",
        "active_sessions": len(manager.active_sessions),
        "sparrow_available": processor_pool._model_path is not None
    }


@app.post("/exotel-status")
async def exotel_status_callback(request: Request):
    """
    HTTP endpoint for Exotel StatusCallback webhooks.

    Exotel sends status updates when:
    - 'answered' event: When each leg (From/To) answers the call
    - 'terminal' event: When the call ends

    The StatusCallback is set when making the call via:
    StatusCallback=https://your-server.ngrok.io/exotel-status
    StatusCallbackContentType=application/json
    StatusCallbackEvents[0]=terminal
    StatusCallbackEvents[1]=answered

    Exotel JSON format for 'answered' event:
    {
        "CallSid": "abc123",
        "EventType": "answered",
        "Legs": [
            {
                "Id": 1,
                "OnCallDuration": 0,
                "AnsweredBy": "Human"  // Only for leg2 (To number)
            }
        ]
    }

    This handler forwards the status to connected Flutter clients via WebSocket.
    """
    try:
        # Get content type
        content_type = request.headers.get("content-type", "")

        if "application/json" in content_type:
            data = await request.json()
        else:
            # Form data fallback
            form = await request.form()
            data = dict(form)

        logger.info(f"Exotel StatusCallback received: {json.dumps(data, indent=2)}")

        # Extract call info
        call_sid = data.get("CallSid") or data.get("call_sid") or ""
        event_type = data.get("EventType") or data.get("event_type") or ""

        # Extract AnsweredBy at the call level (Exotel provides it here, not in leg objects)
        # This is set by MachineDetection feature and applies to leg2 (destination number)
        call_level_answered_by = data.get("AnsweredBy") or data.get("answered_by")

        # Extract leg info from Legs array
        legs = data.get("Legs") or data.get("legs") or []

        # Process each leg status - use array index as leg number (1-based)
        for idx, leg in enumerate(legs):
            # Leg index: 0 = Leg1 (From/Sales), 1 = Leg2 (To/Lead)
            leg_number = idx + 1
            leg_id = leg.get("Id") or leg.get("id") or leg_number
            leg_status = leg.get("Status") or leg.get("status")
            # Check leg-level AnsweredBy first, fall back to call-level for leg2
            answered_by = leg.get("AnsweredBy") or leg.get("answered_by")
            if answered_by is None and leg_number == 2:
                # For leg2, use call-level AnsweredBy (from MachineDetection)
                answered_by = call_level_answered_by
            on_call_duration = leg.get("OnCallDuration") or leg.get("on_call_duration") or 0

            logger.info(f"Leg {leg_number} status: event={event_type}, status={leg_status}, answeredBy={answered_by}")

            # Create leg status event for Flutter
            leg_status_event = {
                "event": "leg_status",
                "call_sid": call_sid,
                "event_type": event_type.lower(),  # 'answered' or 'terminal'
                "leg_number": leg_number,  # 1 = From/Sales, 2 = To/Lead
                "leg_status": leg_status,
                "answered_by": answered_by,
                "on_call_duration": on_call_duration,
                "timestamp": datetime.now().isoformat()
            }

            # Forward to connected Flutter client
            # Try exact call_sid match first
            if call_sid in manager.active_sessions:
                session = manager.active_sessions[call_sid]
                if session.client_ws:
                    try:
                        await session.client_ws.send_json(leg_status_event)
                        logger.info(f"Forwarded leg status to client: {call_sid}")
                    except Exception as e:
                        logger.warning(f"Failed to forward leg status: {e}")
            else:
                # Try to find session by partial match or any active session
                for sid, session in manager.active_sessions.items():
                    if session.client_ws and session.is_active:
                        try:
                            await session.client_ws.send_json(leg_status_event)
                            logger.info(f"Forwarded leg status to client (session {sid})")
                        except Exception as e:
                            logger.warning(f"Failed to forward leg status: {e}")

        return {"status": "received", "call_sid": call_sid, "event_type": event_type}

    except Exception as e:
        logger.error(f"Error processing StatusCallback: {e}")
        # Return 200 anyway so Exotel doesn't retry
        return {"status": "error", "message": str(e)}


@app.get("/stats")
async def get_stats():
    """Get server statistics."""
    sessions_info = {}
    for call_sid, session in manager.active_sessions.items():
        sessions_info[call_sid] = {
            "has_exotel": session.exotel_ws is not None,
            "has_client": session.client_ws is not None,
            "is_active": session.is_active,
            "processor_stats": session.processor.get_stats() if session.processor else None
        }

    return {
        "active_sessions": len(manager.active_sessions),
        "pending_clients": len(manager.pending_clients),
        "sessions": sessions_info
    }


@app.websocket("/exotel-stream")
async def exotel_stream_endpoint(websocket: WebSocket):
    """
    WebSocket endpoint for Exotel audio streams.

    Exotel sends audio data in the following format:
    - Binary frames: Raw PCM audio (8kHz, 16-bit, mono)
    - JSON frames: Control messages (start, stop, metadata)

    Expected Exotel message format:
    {
        "event": "start" | "media" | "stop",
        "streamSid": "...",
        "callSid": "...",
        "media": {
            "payload": "<base64 audio>",
            "timestamp": "...",
            "track": "inbound" | "outbound"
        }
    }
    """
    call_sid = None
    session = None

    try:
        # Wait for initial connection message to get call_sid
        await websocket.accept()

        # Receive first message to get call metadata
        first_message = await websocket.receive()

        if "text" in first_message:
            data = json.loads(first_message["text"])
            event = data.get("event", "start")

            # Log the full first message to understand Exotel's format
            logger.info(f"Exotel first message: {json.dumps(data, indent=2)[:500]}")

            # Extract call_sid from various possible locations
            call_sid = (
                data.get("callSid") or
                data.get("call_sid") or
                data.get("start", {}).get("callSid") or
                data.get("start", {}).get("call_sid") or
                data.get("streamSid") or  # Sometimes stream SID is used
                "unknown"
            )
            logger.info(f"Extracted call_sid: {call_sid}")

            # Extract media format info
            start_info = data.get("start", {})
            media_format = start_info.get("mediaFormat", {})
            encoding = media_format.get("encoding", "audio/x-mulaw")
            sample_rate = media_format.get("sampleRate", 8000)

            logger.info(f"Exotel stream started: {call_sid}, event: {event}")
            logger.info(f"  Audio format: {encoding}, {sample_rate}Hz")
            logger.info(f"  Full mediaFormat: {media_format}")

            # Create session with full metadata
            session = CallSession(
                call_sid=call_sid,
                exotel_ws=websocket,
                processor=processor_pool.get_processor(call_sid),
                metadata=data
            )
            session.init_audio_files()  # Start saving audio
            manager.active_sessions[call_sid] = session

            # Notify client if waiting - try exact match first, then any pending client
            matched_pending_sid = None
            if call_sid in manager.pending_clients:
                matched_pending_sid = call_sid
            elif len(manager.pending_clients) > 0:
                # No exact match, use first pending client (SID mismatch case)
                matched_pending_sid = list(manager.pending_clients.keys())[0]
                logger.info(f"No exact SID match, auto-matching pending client {matched_pending_sid} to session {call_sid}")

            if matched_pending_sid:
                for client_ws in manager.pending_clients[matched_pending_sid]:
                    session.client_ws = client_ws
                    await client_ws.send_json({
                        "event": "stream_start",
                        "call_sid": call_sid,
                        "audio_format": {
                            "encoding": encoding,
                            "sample_rate": sample_rate
                        }
                    })
                del manager.pending_clients[matched_pending_sid]
                logger.info(f"Client matched to Exotel session: {call_sid}")

        elif "bytes" in first_message:
            # Binary first message - generate call_sid
            import uuid
            call_sid = str(uuid.uuid4())[:8]
            session = CallSession(
                call_sid=call_sid,
                exotel_ws=websocket,
                processor=processor_pool.get_processor(call_sid),
            )
            session.init_audio_files()  # Start saving audio
            manager.active_sessions[call_sid] = session

            # Process the first audio frame
            audio_data = first_message["bytes"]
            await process_audio_frame(session, audio_data)

        # Main message loop
        while True:
            message = await websocket.receive()

            if "text" in message:
                data = json.loads(message["text"])
                event = data.get("event", "")

                if event == "start":
                    # Update session metadata with start info
                    if session:
                        session.metadata.update(data)
                        start_info = data.get("start", {})
                        media_format = start_info.get("mediaFormat", {})
                        logger.info(f"Stream start received: {media_format}")

                elif event == "media":
                    # Exotel media message format
                    media = data.get("media", {})
                    payload = media.get("payload", "")

                    if payload:
                        audio_data = base64.b64decode(payload)

                        # Log first media frame for debugging
                        if not hasattr(session, '_first_media_logged'):
                            session._first_media_logged = True
                            logger.info(f"First media frame received:")
                            logger.info(f"  Media metadata: {media}")
                            logger.info(f"  Payload length: {len(payload)} base64 chars")
                            logger.info(f"  Decoded length: {len(audio_data)} bytes")
                            logger.info(f"  First 20 bytes: {list(audio_data[:20])}")

                        await process_audio_frame(session, audio_data, media)

                elif event == "stop":
                    logger.info(f"Exotel stream stopped: {call_sid}")
                    break

                elif event == "mark":
                    # Acknowledgment marker from Exotel
                    pass

                elif event == "connected":
                    # Initial connection acknowledgment
                    logger.info(f"Exotel connected: {data}")

            elif "bytes" in message:
                # Raw binary audio data
                audio_data = message["bytes"]
                await process_audio_frame(session, audio_data)

    except WebSocketDisconnect:
        logger.info(f"Exotel WebSocket disconnected: {call_sid}")
    except Exception as e:
        logger.error(f"Error in Exotel stream: {e}")
    finally:
        if call_sid:
            await manager.disconnect_exotel(call_sid)


async def process_audio_frame(session: CallSession, audio_data: bytes, metadata: dict = None):
    """Process a single audio frame through Krisp."""
    if not session or not session.processor:
        return

    try:
        # Save original Exotel bytes (before any conversion)
        if hasattr(session, 'original_file') and session.original_file:
            try:
                session.original_file.write(audio_data)
            except Exception as e:
                logger.error(f"Error saving original audio: {e}")

        # Get encoding from session metadata or current metadata
        encoding = "audio/x-mulaw"  # Default for telephony
        if metadata and "encoding" in metadata:
            encoding = metadata["encoding"]
        elif session.metadata:
            # Check start message for mediaFormat
            start_info = session.metadata.get("start", {})
            media_format = start_info.get("mediaFormat", {})
            encoding = media_format.get("encoding", encoding)

        # Convert to PCM16 if needed (Krisp expects PCM16)
        pcm_audio = detect_and_convert_audio(audio_data, encoding)

        # Save raw audio (after conversion, before Krisp processing)
        if session.raw_audio_file:
            try:
                session.raw_audio_file.writeframes(pcm_audio)
            except Exception as e:
                logger.error(f"Error saving raw audio: {e}")

        # Process through Sparrow
        processed_audio, has_voice, vad_confidence = session.processor.process_audio(pcm_audio)

        # Save processed audio (after Sparrow processing)
        if session.processed_audio_file:
            try:
                session.processed_audio_file.writeframes(processed_audio)
            except Exception as e:
                logger.error(f"Error saving processed audio: {e}")

        # For the Flutter client (Deepgram transcription), use processed audio when it
        # contains a real signal. Fall back to raw PCM in two cases:
        #   1. Sparrow is still buffering → processed_audio is b""
        #   2. Sparrow suppressed all signal → audio level is near zero
        # Without this fallback Deepgram receives silence and produces no transcripts.
        processed_level = get_audio_level(processed_audio)
        if processed_audio and processed_level >= 0.001:
            audio_for_client = processed_audio
        else:
            audio_for_client = pcm_audio  # raw PCM ensures Deepgram always gets speech

        audio_level = get_audio_level(audio_for_client)

        # Log periodically to show audio is flowing
        if hasattr(session, '_frame_count'):
            session._frame_count += 1
        else:
            session._frame_count = 1

        if session._frame_count % 50 == 0:
            logger.info(
                f"[{session.call_sid}] Processed {session._frame_count} frames | "
                f"VAD: {has_voice} | SparrowLevel: {processed_level:.3f} | "
                f"ClientLevel: {audio_level:.3f}"
            )

        # Send audio to connected client
        client_connected = session.client_ws is not None
        if session._frame_count % 100 == 0:
            logger.info(f"[{session.call_sid}] Client connected: {client_connected}, "
                       f"Sending {len(audio_for_client)} bytes to client")

        await manager.send_audio_to_client(
            session.call_sid,
            audio_for_client,
            {
                "has_voice": has_voice,
                "vad_confidence": vad_confidence,
                "audio_level": audio_level,
                "timestamp": metadata.get("timestamp") if metadata else None,
                "track": metadata.get("track") if metadata else "inbound"
            }
        )

    except Exception as e:
        logger.error(f"Error processing audio frame: {e}")


@app.websocket("/audio-stream")
async def client_audio_stream(websocket: WebSocket):
    """
    WebSocket endpoint for Flutter/web clients to receive processed audio.

    Clients connect here and send their call_sid to receive audio for that call.
    """
    call_sid = None

    try:
        await websocket.accept()

        # Wait for handshake with call_sid
        handshake = await websocket.receive_json()
        call_sid = handshake.get("call_sid")

        if not call_sid:
            await websocket.send_json({"error": "call_sid required"})
            await websocket.close()
            return

        logger.info(f"Client connecting for call: {call_sid}")

        # Register client
        session = await manager.connect_client(websocket, call_sid)

        if session:
            await websocket.send_json({
                "event": "connected",
                "call_sid": call_sid,
                "stream_active": session.exotel_ws is not None
            })
        else:
            await websocket.send_json({
                "event": "waiting",
                "call_sid": call_sid,
                "message": "Waiting for Exotel stream..."
            })

        # Keep connection alive and handle client messages
        while True:
            try:
                message = await asyncio.wait_for(
                    websocket.receive(),
                    timeout=config.server.ping_interval
                )

                if "text" in message:
                    data = json.loads(message["text"])
                    cmd = data.get("command")

                    if cmd == "ping":
                        await websocket.send_json({"event": "pong"})

                    elif cmd == "get_stats":
                        if call_sid in manager.active_sessions:
                            session = manager.active_sessions[call_sid]
                            stats = session.processor.get_stats() if session.processor else {}
                            await websocket.send_json({
                                "event": "stats",
                                "stats": stats
                            })

                    elif cmd == "disconnect":
                        break

            except asyncio.TimeoutError:
                # Send ping to keep alive
                try:
                    await websocket.send_json({"event": "ping"})
                except Exception:
                    break

    except WebSocketDisconnect:
        logger.info(f"Client disconnected: {call_sid}")
    except Exception as e:
        logger.error(f"Error in client stream: {e}")
    finally:
        if call_sid:
            await manager.disconnect_client(call_sid, websocket)


@app.websocket("/client-stream/{call_sid}")
async def client_stream_by_sid(websocket: WebSocket, call_sid: str):
    """
    Alternative endpoint with call_sid in URL path.
    Useful for direct connections without handshake.
    """
    try:
        await websocket.accept()
        session = await manager.connect_client(websocket, call_sid)

        await websocket.send_json({
            "event": "connected",
            "call_sid": call_sid,
            "stream_active": session.exotel_ws is not None if session else False
        })

        # Keep alive loop
        while True:
            try:
                message = await asyncio.wait_for(
                    websocket.receive(),
                    timeout=config.server.ping_interval
                )

                if "text" in message:
                    data = json.loads(message["text"])
                    if data.get("command") == "disconnect":
                        break

            except asyncio.TimeoutError:
                try:
                    await websocket.send_json({"event": "ping"})
                except Exception:
                    break

    except WebSocketDisconnect:
        logger.info(f"Client disconnected: {call_sid}")
    except Exception as e:
        logger.error(f"Error in client stream: {e}")
    finally:
        await manager.disconnect_client(call_sid, websocket)


@app.post("/simulate-exotel/{call_sid}")
async def simulate_exotel_stream(call_sid: str):
    """
    Endpoint to simulate Exotel stream for testing.
    Creates a test session that can receive audio via POST.
    """
    if call_sid in manager.active_sessions:
        raise HTTPException(status_code=400, detail="Session already exists")

    session = CallSession(
        call_sid=call_sid,
        processor=processor_pool.get_processor(call_sid)
    )
    manager.active_sessions[call_sid] = session

    return {
        "status": "created",
        "call_sid": call_sid,
        "message": "Session created. Connect client to /audio-stream or /client-stream/{call_sid}"
    }


@app.post("/simulate-audio/{call_sid}")
async def simulate_audio(call_sid: str, audio_b64: str):
    """
    POST audio data to a simulated session for testing.
    Audio should be base64-encoded PCM data.
    """
    if call_sid not in manager.active_sessions:
        raise HTTPException(status_code=404, detail="Session not found")

    session = manager.active_sessions[call_sid]
    audio_data = base64.b64decode(audio_b64)

    await process_audio_frame(session, audio_data, {"track": "simulated"})

    return {"status": "processed", "bytes": len(audio_data)}


def main():
    """Run the server."""
    uvicorn.run(
        "main:app",
        host=config.server.host,
        port=config.server.port,
        reload=True,
        log_level="info"
    )


if __name__ == "__main__":
    main()
