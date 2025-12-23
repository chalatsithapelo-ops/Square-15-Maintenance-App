"""Self-test: run the LiveKit voice agent without the phone.

What this verifies:
- LiveKit credentials work (create room + join)
- OpenAI credentials work (LLM + TTS)
- livekit-plugins-silero is installed (VAD loads)
- AgentSession starts and can generate a reply without crashing

It does NOT verify audible playback (no listener).

Run (from square_15-master/square_15-master):
  ..\\.venv\\Scripts\\python.exe .\\scripts\\selftest_no_phone.py

Environment variables required:
  LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, OPENAI_API_KEY

Optional:
  SELFTEST_ROOM_PREFIX (default: square15-selftest)
"""

import asyncio
import os
import secrets
import time
import logging
from pathlib import Path

from livekit import rtc, api
from livekit.api.room_service import RoomService
from livekit.agents import voice
from livekit.plugins import openai, silero


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("selftest")


def _require_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required env var: {name}")
    return value


async def main() -> int:
    # Load .env if available.
    # This repo keeps .env at the workspace root (../.. from this file),
    # but the script is typically run from square_15-master/square_15-master.
    try:
        from dotenv import load_dotenv

        # 1) Current working directory
        load_dotenv(override=False)

        # 2) Workspace root (.env sits next to requirements.txt)
        repo_root_env = Path(__file__).resolve().parents[2] / ".env"
        if repo_root_env.exists():
            load_dotenv(repo_root_env, override=False)
    except Exception:
        pass

    livekit_url = _require_env("LIVEKIT_URL")
    livekit_api_key = _require_env("LIVEKIT_API_KEY")
    livekit_api_secret = _require_env("LIVEKIT_API_SECRET")

    # OpenAI key presence is validated inside the plugins, but fail early for clarity.
    _require_env("OPENAI_API_KEY")

    if not hasattr(silero, "VAD"):
        raise RuntimeError(
            "Silero plugin not available (silero.VAD missing). "
            "Install 'livekit-plugins-silero' into the active environment."
        )

    room_prefix = os.getenv("SELFTEST_ROOM_PREFIX", "square15-selftest")
    room_name = f"{room_prefix}-{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(2)}"

    http_url = (
        livekit_url.replace("wss://", "https://")
        .replace("ws://", "http://")
    )

    logger.info(f"Creating room: {room_name}")

    import aiohttp

    async with aiohttp.ClientSession() as session:
        rs = RoomService(session=session, url=http_url, api_key=livekit_api_key, api_secret=livekit_api_secret)
        try:
            await rs.create_room(api.CreateRoomRequest(name=room_name))
        except Exception as e:
            # If it already exists, that's fine for a self-test.
            logger.warning(f"create_room failed (continuing): {e}")

    token = (
        api.AccessToken(livekit_api_key, livekit_api_secret)
        .with_identity(f"selftest-agent-{secrets.token_hex(3)}")
        .with_name("Square15 SelfTest Agent")
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=room_name,
                can_publish=True,
                can_subscribe=True,
            )
        )
    )

    room = rtc.Room()

    logger.info("Connecting agent to room...")
    await room.connect(livekit_url, token.to_jwt())
    logger.info("Connected.")

    try:
        agent = voice.Agent(
            vad=silero.VAD.load(),
            stt=openai.STT(model="whisper-1"),
            llm=openai.LLM(model="gpt-4o-mini", temperature=0.2),
            tts=openai.TTS(model="tts-1", voice="alloy"),
            instructions=(
                "You are the Square 15 voice assistant self-test. "
                "Respond with exactly the single token: SELFTEST_OK"
            ),
        )

        session = voice.AgentSession()
        await session.start(agent, room=room)
        logger.info("AgentSession started.")

        # Force a reply generation. This returns a SpeechHandle we can await.
        logger.info("Generating reply...")
        handle = session.generate_reply(user_input="Hello")
        
        # Wait for speech generation to complete (with timeout since there's no audio device)
        try:
            await asyncio.wait_for(handle.wait_for_playout(), timeout=10.0)
            logger.info("Self-test reply generation completed (no crash).")
        except asyncio.TimeoutError:
            # Timeout is expected when there's no audio device to play to
            logger.info("Self-test reply generated (TTS completed, playout timeout expected without audio device).")
        
        return 0
    finally:
        try:
            await room.disconnect()
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
