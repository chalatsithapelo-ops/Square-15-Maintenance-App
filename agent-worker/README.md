# Square 15 - Cloud Agent Worker

This runs the LiveKit voice AI agent **without your laptop**, so dispatch works anywhere.

## What you deploy
- `livekit-backend` (Node): public HTTPS API for `/api/voice/start`
- `agent-worker` (Python): always-on worker that receives dispatch jobs and speaks in the room

## Agent worker (Docker)

### Required environment variables
- `LIVEKIT_URL` (or `LIVEKIT_WS_URL`)
- `LIVEKIT_API_KEY`
- `LIVEKIT_API_SECRET`
- `LIVEKIT_AGENT_NAME` (must match what backend dispatches; default `square15-voice-assistant`)
- `OPENAI_API_KEY`

### Build locally
From repo root:

```bash
docker build -f agent-worker/Dockerfile -t square15-agent-worker .
```

### Run locally
```bash
docker run --rm \
  -e LIVEKIT_URL=wss://YOUR.livekit.cloud \
  -e LIVEKIT_API_KEY=... \
  -e LIVEKIT_API_SECRET=... \
  -e LIVEKIT_AGENT_NAME=square15-voice-assistant \
  -e OPENAI_API_KEY=... \
  square15-agent-worker
```

## Flutter app configuration

Build with a public backend URL (HTTPS):

```bash
flutter run --dart-define=LIVEKIT_BACKEND_URL=https://YOUR_BACKEND_DOMAIN
```

Or for release builds:

```bash
flutter build apk --dart-define=LIVEKIT_BACKEND_URL=https://YOUR_BACKEND_DOMAIN
```
