"""
LiveKit Voice Agent Worker - Cloud Deploy

This file is a copy of the app worker script, placed in agent-worker/ so you can
upload/deploy a minimal set of files to GitHub/Render.
"""

import os
import asyncio
import logging
from pathlib import Path

from livekit.agents import AutoSubscribe, JobContext, WorkerOptions, cli
from livekit.agents import voice
from livekit.plugins import openai, silero
from livekit import rtc


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
)
logger = logging.getLogger(__name__)


# Load environment variables (optional locally; Render uses service env vars)
try:
    from dotenv import load_dotenv

    load_dotenv(override=False)

    script_path = Path(__file__).resolve()
    candidate_envs = [
        script_path.parent / ".env",
        script_path.parent.parent / ".env",
    ]
    for env_path in candidate_envs:
        if env_path.exists():
            load_dotenv(env_path, override=False)
except ImportError:
    logger.warning("dotenv not available, using system environment variables")


async def entrypoint(ctx: JobContext):
    room_name = ctx.room.name
    logger.info(f"🎯 New job received for room: {room_name}")

    openai_key = os.getenv("OPENAI_API_KEY")
    if not openai_key:
        logger.error("❌ OPENAI_API_KEY not set!")
        return

    logger.info(f"📡 Connecting to room: {room_name}")

    max_retries = 3
    for attempt in range(max_retries):
        try:
            await ctx.connect(auto_subscribe=AutoSubscribe.AUDIO_ONLY)
            logger.info(f"✅ Agent connected to room: {room_name}")
            break
        except Exception as e:
            if attempt < max_retries - 1:
                logger.warning(
                    f"⚠️ Connection attempt {attempt + 1} failed: {e}. Retrying..."
                )
                await asyncio.sleep(2**attempt)
            else:
                logger.error(f"❌ Failed to connect after {max_retries} attempts: {e}")
                raise

    logger.info("🎤 Loading Voice Activity Detection...")
    if not hasattr(silero, "VAD"):
        raise RuntimeError(
            "Silero plugin not available (silero.VAD missing). Install 'livekit-plugins-silero'."
        )
    vad = silero.VAD.load()

    logger.info("🤖 Creating voice agent...")
    agent = voice.Agent(
        vad=vad,
        stt=openai.STT(model="whisper-1", language="en"),
        llm=openai.LLM(model="gpt-4o-mini", temperature=0.7),
        tts=openai.TTS(model="tts-1", voice="alloy"),
        instructions=(
            "You are the Square 15 voice assistant. "
            "Speak clearly and keep your responses short and helpful. "
            "Assist users with maintenance bookings, schedules, and general support. "
            "Be friendly and professional. "
            "Always respond to what the user says. "
            "If you don't understand, politely ask the user to repeat. "
            "Keep responses under 30 seconds."
        ),
    )

    logger.info("🚀 Starting agent session...")
    session = voice.AgentSession()
    await session.start(agent, room=ctx.room)
    logger.info("✅ Agent session started and running!")

    try:
        await session.say(
            "Hello! I'm your Square 15 voice assistant. How can I help you today?",
            allow_interruptions=True,
        )
        logger.info("✅ Greeting sent")
    except Exception as e:
        logger.warning(f"⚠️ Could not send greeting: {e}")

    while ctx.room.connection_state != rtc.ConnectionState.CONN_DISCONNECTED:
        await asyncio.sleep(1)


async def request_handler(ctx: JobContext):
    try:
        await entrypoint(ctx)
    except Exception as e:
        logger.error(f"❌ Fatal error in request handler: {e}", exc_info=True)


if __name__ == "__main__":
    logger.info("🚀 Starting Square 15 Voice Agent Worker...")
    logger.info("📡 Listening for room join events...")

    agent_name = os.getenv("LIVEKIT_AGENT_NAME", "square15-voice-assistant")
    logger.info(f"🤝 Explicit dispatch agent_name: {agent_name}")

    cli.run_app(
        WorkerOptions(
            entrypoint_fnc=request_handler,
            agent_name=agent_name,
            port=0,
        ),
    )
