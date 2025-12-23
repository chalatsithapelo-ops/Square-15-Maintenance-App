"""Quick validation: agent creation without network"""
import os
import sys
from pathlib import Path

# Load .env
try:
    from dotenv import load_dotenv
    repo_root_env = Path(__file__).resolve().parents[2] / ".env"
    if repo_root_env.exists():
        load_dotenv(repo_root_env)
        print(f"[OK] Loaded {repo_root_env}")
except Exception as e:
    print(f"[WARN] .env loading: {e}")

# Validate required env vars
required = ["LIVEKIT_URL", "LIVEKIT_API_KEY", "LIVEKIT_API_SECRET", "OPENAI_API_KEY"]
missing = [v for v in required if not os.getenv(v)]
if missing:
    print(f"[FAIL] Missing env vars: {', '.join(missing)}")
    sys.exit(1)

print("[OK] All required env vars present")

# Test imports
try:
    from livekit.agents import voice
    from livekit.plugins import openai, silero
    print("[OK] Imports successful")
except Exception as e:
    print(f"[FAIL] Import error: {e}")
    sys.exit(1)

# Test agent creation (no network)
try:
    print("Creating voice agent...")
    agent = voice.Agent(
        vad=silero.VAD.load(),
        stt=openai.STT(model="whisper-1"),
        llm=openai.LLM(model="gpt-4o-mini", temperature=0.2),
        tts=openai.TTS(model="tts-1", voice="alloy"),
        instructions="Test agent",
    )
    print("[OK] Voice agent created")
    print(f"     VAD: {agent._vad is not None}")
    print(f"     STT: {agent._stt is not None}")
    print(f"     LLM: {agent._llm is not None}")
    print(f"     TTS: {agent._tts is not None}")
except Exception as e:
    print(f"[FAIL] Agent creation: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)

print("\n=== ALL CHECKS PASSED ===")
print("Ready to run full selftest_no_phone.py")
