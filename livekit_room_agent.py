import os
import asyncio
import json
import time
from dataclasses import dataclass

try:
    from dotenv import load_dotenv
except ImportError:
    load_dotenv = None

import requests

from livekit import rtc
from livekit.agents.voice.agent_session import AgentSession
from livekit.agents.voice.room_io import RoomIO, RoomOptions
from livekit.agents.voice.agent import Agent
from livekit.plugins import openai as openai_plugins
from livekit.plugins import silero


@dataclass
class Config:
    livekit_url: str
    backend_url: str | None
    room_name: str
    agent_identity: str
    openai_api_key: str | None


def load_config() -> Config:
    if load_dotenv:
        load_dotenv()

    livekit_url = os.getenv("LIVEKIT_URL", "wss://square-15-maintenance-app-n6ijx3po.livekit.cloud")
    backend_url = os.getenv("BACKEND_URL", "http://192.168.123.36:3000")
    room_name = os.getenv("ROOM_NAME", "square15-voice-assistant")
    agent_identity = os.getenv("AGENT_IDENTITY", "square15-agent")
    openai_api_key = os.getenv("OPENAI_API_KEY")

    return Config(
        livekit_url=livekit_url,
        backend_url=backend_url,
        room_name=room_name,
        agent_identity=agent_identity,
        openai_api_key=openai_api_key,
    )


def fetch_token(backend_url: str, room_name: str, participant_name: str) -> str:
    resp = requests.post(
        f"{backend_url}/api/token",
        headers={"Content-Type": "application/json"},
        data=json.dumps({"roomName": room_name, "participantName": participant_name}),
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["token"]


async def run_agent(cfg: Config) -> None:
    if cfg.openai_api_key is None:
        print("[!] OPENAI_API_KEY not set. Please set it in your environment.")
        return

    # Prepare models (OpenAI STT, TTS, LLM) - use standard (non-realtime) STT
    stt = openai_plugins.STT(
        api_key=cfg.openai_api_key,
        model="whisper-1"
    )
    tts = openai_plugins.TTS(
        api_key=cfg.openai_api_key,
        model="tts-1",
        voice="alloy"
    )
    llm = openai_plugins.LLM(
        api_key=cfg.openai_api_key,
        model="gpt-4o-mini"
    )
    voice_vad = silero.VAD.load()

    # Connect to LiveKit room
    room = rtc.Room()

    print(f"[*] Connecting to room '{cfg.room_name}' at {cfg.livekit_url} ...")
    # Prefer LK_TOKEN if provided; fallback to backend; else instruct user
    token = os.getenv("LK_TOKEN")
    if not token:
        if cfg.backend_url:
            try:
                token = fetch_token(cfg.backend_url, cfg.room_name, cfg.agent_identity)
            except Exception as e:
                print(f"[!] Could not reach backend at {cfg.backend_url}: {e}")
                print("[!] No token available. Set LK_TOKEN env var or start the backend.")
                return
        else:
            print("[!] No token available. Set LK_TOKEN env var or provide BACKEND_URL.")
            return

    await room.connect(cfg.livekit_url, token)
    print("[+] Connected. Waiting for participant audio...")

    # Create AgentSession
    session = AgentSession(
        stt=stt,
        vad=voice_vad,
        llm=llm,
        tts=tts,
        allow_interruptions=True,
        min_endpointing_delay=0.4,
        max_endpointing_delay=3.0,
    )

    # Minimal agent instructions
    agent = Agent(
        instructions=(
            "You are the Square 15 voice assistant."
            " Speak clearly, keep replies short and helpful."
            " Assist with maintenance bookings, schedules, and general support."
        ),
        stt=stt,
        tts=tts,
        llm=llm,
        allow_interruptions=True,
    )

    await session.start(agent, room=room, room_options=RoomOptions(
        participant_identity=os.getenv("PARTICIPANT_IDENTITY") if os.getenv("PARTICIPANT_IDENTITY") else None,
    ))

    print("[+] Agent started! Listening for audio from participants...")

    # Keep running until room disconnects
    try:
        while True:
            if room.connection_state == rtc.ConnectionState.CONN_DISCONNECTED:
                print("[!] Room disconnected. Exiting.")
                break
            await asyncio.sleep(1.0)
    finally:
        await session.aclose()
        await room.disconnect()


def main() -> None:
    cfg = load_config()
    try:
        asyncio.run(run_agent(cfg))
    except KeyboardInterrupt:
        print("\n[+] Stopped by user.")


if __name__ == "__main__":
    main()
