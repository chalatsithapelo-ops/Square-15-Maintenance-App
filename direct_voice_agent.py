"""
LiveKit Voice Agent - Direct Room Join with Auto-Reconnection
Directly joins the square15-voice-assistant room with robust error handling
"""
import os
import asyncio
import logging
from livekit import rtc
from livekit.agents import llm
from livekit.plugins import openai, silero
from livekit.agents import voice

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Load environment variables
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    logger.warning("dotenv not available")

# Configuration
LIVEKIT_URL = os.getenv("LIVEKIT_URL", "wss://square-15-maintenance-app-n6ijx3po.livekit.cloud")
LIVEKIT_API_KEY = os.getenv("LIVEKIT_API_KEY", "APIfA2HcvgKpuuV")
LIVEKIT_API_SECRET = os.getenv("LIVEKIT_API_SECRET", "s6gagz8IeavnqDrWj4ZwUIB91wii1k5BwrC8vF2rrgR")
ROOM_NAME = "square15-voice-assistant"
AGENT_IDENTITY = "square15-voice-agent"
MAX_RECONNECT_ATTEMPTS = 5
RECONNECT_DELAY = 5  # seconds


async def create_agent_session(room):
    """Create and start voice agent session with error handling"""
    try:
        logger.info("🤖 Creating voice agent...")
        
        # Create the voice agent
        if not hasattr(silero, "VAD"):
            raise RuntimeError(
                "Silero plugin not available (silero.VAD missing). "
                "Install 'livekit-plugins-silero' into the active environment."
            )

        agent = voice.Agent(
            vad=silero.VAD.load(),
            stt=openai.STT(model="whisper-1"),
            llm=openai.LLM(model="gpt-4o-mini", temperature=0.7),
            tts=openai.TTS(model="tts-1", voice="alloy"),
            instructions=(
                "You are the Square 15 voice assistant. "
                "Speak clearly and keep your responses short and helpful. "
                "Assist users with maintenance bookings, schedules, and general support. "
                "Be friendly and professional. "
                "Always respond to what the user says. "
                "If you don't understand, politely ask the user to repeat."
            ),
        )
        
        logger.info("🚀 Starting agent session...")
        session = voice.AgentSession()
        await session.start(agent, room=room)
        logger.info("✅ Agent session started successfully!")
        
        # Greet the user
        try:
            await session.say(
                "Hello! I'm your Square 15 voice assistant. How can I help you today?",
                allow_interruptions=True
            )
        except Exception as e:
            logger.warning(f"⚠️ Could not send greeting: {e}")
        
        return session
        
    except Exception as e:
        logger.error(f"❌ Failed to create agent session: {e}", exc_info=True)
        raise


async def connect_to_room():
    """Connect to LiveKit room with retry logic"""
    from livekit import api
    
    # Generate access token for the agent
    token = api.AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET) \
        .with_identity(AGENT_IDENTITY) \
        .with_name("Square 15 Voice Assistant") \
        .with_grants(api.VideoGrants(
            room_join=True,
            room=ROOM_NAME,
            can_publish=True,
            can_subscribe=True,
        ))
    
    room = rtc.Room()
    
    # Connect with retry logic
    max_retries = 3
    for attempt in range(max_retries):
        try:
            logger.info(f"📡 Connecting to room (attempt {attempt + 1}/{max_retries})...")
            await room.connect(LIVEKIT_URL, token.to_jwt())
            logger.info(f"✅ Connected to room: {ROOM_NAME}")
            return room
        except Exception as e:
            if attempt < max_retries - 1:
                logger.warning(f"⚠️ Connection failed: {e}. Retrying in {2 ** attempt}s...")
                await asyncio.sleep(2 ** attempt)
            else:
                logger.error(f"❌ Failed to connect after {max_retries} attempts")
                raise


async def monitor_connection(room, session):
    """Monitor room connection and handle disconnections"""
    try:
        while True:
            await asyncio.sleep(2)
            
            # Check connection state
            if room.connection_state == rtc.ConnectionState.CONN_DISCONNECTED:
                logger.warning("⚠️ Room disconnected!")
                return False
            elif room.connection_state == rtc.ConnectionState.CONN_RECONNECTING:
                logger.info("🔄 Room reconnecting...")
            
    except asyncio.CancelledError:
        logger.info("⚠️ Monitoring cancelled")
        return False
    except Exception as e:
        logger.error(f"❌ Error monitoring connection: {e}")
        return False


async def main():
    """Main entry point with auto-reconnection logic"""
    reconnect_attempts = 0
    
    while reconnect_attempts < MAX_RECONNECT_ATTEMPTS:
        room = None
        session = None
        
        try:
            logger.info(f"🚀 Starting agent (attempt {reconnect_attempts + 1}/{MAX_RECONNECT_ATTEMPTS})")
            logger.info(f"📍 Room: {ROOM_NAME}")
            logger.info(f"🌐 URL: {LIVEKIT_URL}")
            
            # Connect to room
            room = await connect_to_room()
            
            # Create agent session
            session = await create_agent_session(room)
            
            # Reset reconnect counter on successful connection
            reconnect_attempts = 0
            
            # Monitor connection
            logger.info("👀 Monitoring connection... (Press Ctrl+C to stop)")
            await monitor_connection(room, session)
            
            logger.warning("⚠️ Connection lost, will attempt to reconnect...")
            
        except KeyboardInterrupt:
            logger.info("\n🛑 Shutdown requested by user")
            break
            
        except Exception as e:
            logger.error(f"❌ Error in main loop: {e}", exc_info=True)
            reconnect_attempts += 1
            
        finally:
            # Cleanup
            try:
                if room:
                    await room.disconnect()
                    logger.info("🔌 Disconnected from room")
            except Exception as e:
                logger.error(f"⚠️ Error during cleanup: {e}")
        
        # Wait before reconnecting
        if reconnect_attempts < MAX_RECONNECT_ATTEMPTS:
            logger.info(f"⏳ Waiting {RECONNECT_DELAY}s before reconnecting...")
            await asyncio.sleep(RECONNECT_DELAY)
    
    if reconnect_attempts >= MAX_RECONNECT_ATTEMPTS:
        logger.error(f"❌ Max reconnection attempts ({MAX_RECONNECT_ATTEMPTS}) reached. Exiting.")
    else:
        logger.info("✅ Agent shutdown complete")


if __name__ == "__main__":
    logger.info("=" * 60)
    logger.info("🎙️  Square 15 Voice Agent - Direct Connect")
    logger.info("=" * 60)
    
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("\n✅ Agent stopped by user")
    except Exception as e:
        logger.error(f"❌ Fatal error: {e}", exc_info=True)
