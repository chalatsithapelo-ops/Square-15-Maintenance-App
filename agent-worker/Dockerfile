FROM python:3.12-slim

WORKDIR /app

# System deps (minimal; add build-essential only if needed for wheels)
RUN pip install --no-cache-dir --upgrade pip

# Python dependencies
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

# Copy worker script (kept local to this folder for minimal uploads)
COPY voice_agent_worker.py /app/voice_agent_worker.py

# Runtime env vars are expected to be provided by your hosting platform:
# LIVEKIT_URL or LIVEKIT_WS_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET,
# LIVEKIT_AGENT_NAME, OPENAI_API_KEY

CMD ["python", "/app/voice_agent_worker.py", "start"]
