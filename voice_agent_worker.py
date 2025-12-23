"""
LiveKit Voice Agent Worker - Production Ready
Automatically connects to rooms and responds to user audio with robust error handling
"""
import os
import asyncio
import logging
from pathlib import Path
from livekit.agents import AutoSubscribe, JobContext, WorkerOptions, cli
from livekit.plugins import openai, silero
from livekit.agents import voice
from livekit import rtc

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Load environment variables
try:
    from dotenv import load_dotenv

    # 1) Current working directory
    load_dotenv(override=False)

    # 2) Common locations relative to this file (supports Docker/cloud layouts too)
    script_path = Path(__file__).resolve()
    candidate_envs = [
        script_path.parent.parent / ".env",  # .../scripts/../.env
        script_path.parents[2] / ".env",     # workspace root in this repo layout
    ]
    for env_path in candidate_envs:
        if env_path.exists():
            load_dotenv(env_path, override=False)
except ImportError:
    logger.warning("dotenv not available, using system environment variables")


async def entrypoint(ctx: JobContext):
    """
    Entry point for the voice assistant agent.
    This function is called whenever a participant joins a room.
    Includes comprehensive error handling and recovery.
    """
    room_name = ctx.room.name
    logger.info(f"🎯 New job received for room: {room_name}")
    
    try:
        # Validate environment variables
        openai_key = os.getenv("OPENAI_API_KEY")
        if not openai_key:
            logger.error("❌ OPENAI_API_KEY not set!")
            return
        
        logger.info(f"📡 Connecting to room: {room_name}")
        
        # Connect to the room with retry logic
        max_retries = 3
        for attempt in range(max_retries):
            try:
                await ctx.connect(auto_subscribe=AutoSubscribe.AUDIO_ONLY)
                logger.info(f"✅ Agent connected to room: {room_name}")
                break
            except Exception as e:
                if attempt < max_retries - 1:
                    logger.warning(f"⚠️ Connection attempt {attempt + 1} failed: {e}. Retrying...")
                    await asyncio.sleep(2 ** attempt)  # Exponential backoff
                else:
                    logger.error(f"❌ Failed to connect after {max_retries} attempts: {e}")
                    raise

        # Initialize VAD with error handling
        try:
            logger.info("🎤 Loading Voice Activity Detection...")

            # livekit-plugins-silero provides silero.VAD (and VADStream). If the package is
            # missing, older namespace stubs can exist without VAD.
            if not hasattr(silero, "VAD"):
                raise RuntimeError(
                    "Silero plugin not available (silero.VAD missing). "
                    "Install 'livekit-plugins-silero' into the active environment."
                )

            vad = silero.VAD.load()
        except Exception as e:
            logger.error(f"❌ Failed to load VAD: {e}")
            raise

        # Create voice agent with robust configuration
        logger.info("🤖 Creating voice agent...")
        try:
            agent = voice.Agent(
                vad=vad,
                stt=openai.STT(
                    model="whisper-1",
                    language="en"
                ),
                llm=openai.LLM(
                    model="gpt-4o-mini",
                    temperature=0.7
                ),
                tts=openai.TTS(
                    model="tts-1",
                    voice="alloy"
                ),
                instructions=(
                    "You are the Square 15 voice assistant. "
                    "Speak clearly and keep your responses short and helpful. "
                    "Assist users with maintenance bookings, schedules, and general support. "
                    "Be friendly and professional. "
                    "Always respond to what the user says. "
                    "If you don't understand, politely ask the user to repeat. "
                    "Keep responses under 30 seconds."
                )
            )
            logger.info("✅ Voice agent created successfully")
        except Exception as e:
            logger.error(f"❌ Failed to create agent: {e}")
            raise

        # Start the agent session with error handling
        logger.info("🚀 Starting agent session...")
        try:
            # livekit-agents >=1.x uses AgentSession to run an Agent inside a room.
            session = voice.AgentSession()
            await session.start(agent, room=ctx.room)
            logger.info("✅ Agent session started and running!")

            # Send an initial greeting so the user hears the agent immediately.
            try:
                await session.say(
                    "Hello! I'm your Square 15 voice assistant. How can I help you today?",
                    allow_interruptions=True,
                )
                logger.info("✅ Greeting sent")
            except Exception as e:
                logger.warning(f"⚠️ Could not send greeting: {e}")

            # Keep the job alive while the room is connected/reconnecting.
            while ctx.room.connection_state != rtc.ConnectionState.CONN_DISCONNECTED:
                await asyncio.sleep(1)

        except Exception as e:
            logger.error(f"❌ Error during agent session: {e}")
            # Try to gracefully handle the error
            try:
                logger.info("🔄 Attempting graceful recovery...")
                await asyncio.sleep(2)
            except Exception:
                pass
            raise
            
    except asyncio.CancelledError:
        logger.info(f"⚠️ Job cancelled for room: {room_name}")
        raise
    except Exception as e:
        logger.error(f"❌ Unhandled error in room {room_name}: {e}", exc_info=True)
        raise
    finally:
        logger.info(f"🏁 Agent session ended for room: {room_name}")


async def request_handler(ctx: JobContext):
    """
    Wrapper for entrypoint with additional monitoring
    """
    try:
        await entrypoint(ctx)
    except Exception as e:
        logger.error(f"❌ Fatal error in request handler: {e}", exc_info=True)
        # Don't re-raise to prevent worker crash


if __name__ == "__main__":
    logger.info("🚀 Starting Square 15 Voice Agent Worker...")
    logger.info("📡 Listening for room join events...")

    agent_name = os.getenv("LIVEKIT_AGENT_NAME", "square15-voice-assistant")
    logger.info(f"🤝 Explicit dispatch agent_name: {agent_name}")
    
    # Run the agent worker with production settings
    cli.run_app(
        WorkerOptions(
            entrypoint_fnc=request_handler,
            agent_name=agent_name,
            # Avoid frequent Windows dev restarts failing due to port 8081 already in use.
            # Port 0 requests an ephemeral free port.
            port=0,
            # Worker will automatically reconnect if connection is lost
        ),
    )
