# Square 15 LiveKit Room Voice Agent

A simple local Python agent that joins your LiveKit room and speaks back using OpenAI STT/LLM/TTS.

## Prerequisites
- LiveKit project and token server reachable from your phone and this PC
- Python 3.12 installed
- Environment variable `OPENAI_API_KEY` set

## Install
```powershell
python -m pip install -r square_15-master\scripts\requirements.txt
```

## Run
```powershell
$env:OPENAI_API_KEY="sk-..."   # if not already set
python square_15-master\scripts\livekit_room_agent.py
```

Defaults (override via env):
- `LIVEKIT_URL=wss://square-15-maintenance-app-n6ijx3po.livekit.cloud`
- `BACKEND_URL=http://192.168.123.36:3000`
- `ROOM_NAME=square15-voice-assistant`
- `AGENT_IDENTITY=square15-agent`
- Optionally set `PARTICIPANT_IDENTITY` to target a specific participant.

Keep your phone connected in the app (it shows the room name), then speak and the agent should respond.
