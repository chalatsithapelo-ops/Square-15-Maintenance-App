"""
LiveKit Voice Agent Worker - Cloud Deploy

This file is a copy of the app worker script, placed in agent-worker/ so you can
upload/deploy a minimal set of files to GitHub/Render.
"""

import os
import asyncio
import logging
from pathlib import Path
import inspect
import re

from livekit.agents import AutoSubscribe, JobContext, WorkerOptions, cli
from livekit.agents import voice
from livekit.agents import llm
from livekit.plugins import openai, silero
from livekit import rtc
import json


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
)
logger = logging.getLogger(__name__)


_FORBIDDEN_SPEECH_PATTERNS = [
    # Tool call narration / internal jargon (including the common typo "nagivation")
    re.compile(r"\bcalling\s+ui\s+na(?:g)?ivation\b", re.IGNORECASE),
    re.compile(r"\bcalling\s+ui_navigate\b", re.IGNORECASE),
    re.compile(r"\bui_navigate\b", re.IGNORECASE),
    re.compile(r"\bsquare15_ui\b", re.IGNORECASE),
    re.compile(r"\bsquare15_app\b", re.IGNORECASE),
    re.compile(r"\bSQUARE15_UI\b", re.IGNORECASE),
]


def _sanitize_spoken_text(text: str) -> str:
    """Remove internal/tool narration from anything that could be spoken."""
    t = (text or "").strip()
    if not t:
        return ""
    for pat in _FORBIDDEN_SPEECH_PATTERNS:
        if pat.search(t):
            return ""
    return t


# Load environment variables (optional locally; Render uses service env vars)
# Must never crash if the file is nested differently in a container.
try:
    from dotenv import load_dotenv

    # First, load from process environment (no-op if none)
    load_dotenv(override=False)

    script_path = Path(__file__).resolve()

    # Try nearby .env files without assuming a fixed depth.
    candidate_envs = []
    candidate_envs.append(script_path.parent / ".env")
    for parent in script_path.parents:
        candidate_envs.append(parent / ".env")

    for env_path in candidate_envs:
        if env_path.exists():
            load_dotenv(env_path, override=False)
            break
except Exception as e:
    # Missing python-dotenv or any other issue should not prevent the worker from starting.
    logger.info(f"dotenv not loaded (ok on Render): {e}")


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

    async def _detect_caller_role() -> str:
        """Best-effort role detection from the non-agent participant identity."""
        try:
            # Give LiveKit a moment to populate participants.
            await asyncio.sleep(0.25)
            for _ in range(12):
                try:
                    participants = getattr(ctx.room, "remote_participants", None) or {}
                    for _, p in participants.items():
                        ident = (getattr(p, "identity", "") or "").strip().lower()
                        if ident.startswith("artisan-"):
                            return "artisan"
                        if ident.startswith("client-"):
                            return "client"
                        # If it is not explicitly tagged, treat as client by default.
                        if ident:
                            return "client"
                except Exception:
                    pass
                await asyncio.sleep(0.25)
        except Exception:
            pass
        return "client"

    caller_role = await _detect_caller_role()
    logger.info(f"🧭 Detected caller role: {caller_role}")

    async def _set_agent_metadata(meta: dict) -> None:
        """Set agent participant metadata in a way that works across SDK versions.

        Some LiveKit Python SDK versions expose set_metadata as an async coroutine.
        Others may expose it as a normal function. This helper supports both.
        """
        try:
            if not (ctx.room and ctx.room.local_participant):
                return
            payload = json.dumps(meta)
            result = ctx.room.local_participant.set_metadata(payload)
            if inspect.isawaitable(result):
                await result
        except Exception as e:
            logger.warning(f"⚠️ Failed to set agent metadata: {e}")

    # Emit a handshake metadata packet so the mobile app can verify
    # it is receiving participant metadata updates from the agent.
    try:
        await _set_agent_metadata(
            {
                "type": "square15_ui",
                "action": "agent_ready",
                "payload": {"role": caller_role},
                "text": "Agent ready",
            }
        )
        logger.info("✅ Sent agent_ready metadata")
    except Exception as e:
        logger.warning(f"⚠️ Failed to send agent_ready metadata: {e}")

    def _instructions_for_role(role: str) -> str:
        role = (role or "client").strip().lower()
        role_banner = (
            "You are Lizzy, the Square 15 Voice AI Assistant. "
            f"You are currently speaking to a {role.upper()} user.\n"
        )

        # These rules are written to maximize tool-calling reliability.
        hard_rules = (
            "Hard rules (must follow):\n"
            "- Always introduce yourself as Lizzy.\n"
            "- If the user asks your name (e.g. 'what is your name?'), reply exactly: 'I am Lizzy, how can I help you today?'\n"
            "- If the user asks you to DO something in the app, you MUST call ui_navigate.\n"
            "- Never say you cannot access the app. The way you act in the app is by calling ui_navigate.\n"
            "- When you are ready to dispatch/accept/reject/call, CALL ui_navigate immediately, then confirm in 1 sentence.\n"
            "- Do NOT say 'I will open/dispatch...' unless you have called ui_navigate in that same turn.\n"
            "- Never SAY or narrate tool calls. Do not say phrases like 'calling ui_navigate' or 'calling UI navigator'.\n"
            "- Never speak JSON, code, function names, or metadata. Only speak user-facing sentences.\n"
            "- Never get stuck: do not say 'checking availability' unless you are calling ui_navigate in the SAME turn.\n"
            "- Speak naturally (not robotic). Keep it concise (1-3 short sentences).\n"
        )

        client_flow = (
            "Client workflow (PHOTOS-FIRST dispatch):\n"
            "1) Identify the trade/category from symptoms. If unclear, ask ONE clarifying question.\n"
            "2) Collect the minimum details needed: category_name + problem_description.\n"
            "3) CRITICAL: As soon as you have category + description, you MUST open photo upload FIRST.\n"
            "   CALL ui_navigate(action='dispatch_artisan', category_name=..., problem_description=..., require_photos=True).\n"
            "   The app will enforce minimum 3 photos, then automatically dispatch after photos are uploaded.\n"
            "4) Only ask scheduling/location if the user specifically wants a different time or address.\n"
            "   If needed, include scheduled_date/scheduled_time and/or service_address in the same ui_navigate call.\n"
            "5) For RFQ (big/complex/needs quote/unclear), CALL ui_navigate(action='open_rfq_upload').\n"
            "6) If the user asks to call the assigned artisan, CALL ui_navigate(action='call_assigned_artisan').\n"
            "\nExamples (client):\n"
            "- User: 'I need a plumber, my tap is leaking.'\n"
            "  You: CALL ui_navigate(action='dispatch_artisan', category_name='Plumbing', problem_description='Leaking tap', require_photos=True), then say 'Opening photo upload now.'\n"
        )

        artisan_flow = (
            "Artisan workflow (tasks):\n"
            "- If artisan asks to accept a job/request, you MUST CALL ui_navigate(action='accept_latest_request').\n"
            "- If artisan asks to reject, you MUST CALL ui_navigate(action='reject_latest_request').\n"
            "- If artisan asks to open requests, CALL ui_navigate(action='open_artisan_requests').\n"
            "- If artisan asks for appointments/wallet, use open_artisan_appointments/open_artisan_wallet.\n"
            "- Do not attempt to dispatch artisans while speaking to an artisan.\n"
            "\nExamples (artisan):\n"
            "- User: 'Accept the latest request.'\n"
            "  You: CALL ui_navigate(action='accept_latest_request'), then say 'Done — I accepted it.'\n"
        )

        general = (
            "General behavior:\n"
            "- Speak naturally and professionally. You can answer general questions too.\n"
            "- If user says 'how are you', answer briefly then return to helping.\n"
            "- Always be helpful: acknowledge urgency, then take the next step.\n"
        )

        return "\n".join(
            [
                role_banner,
                hard_rules,
                client_flow if role != "artisan" else artisan_flow,
                general,
            ]
        )

    @llm.function_tool(
        description=(
            "Send a UI navigation command to the Square 15 mobile app. "
            "Use this to open the RFQ photo upload workflow or to ask the app to create an Order booking "
            "(dispatch nearest artisan) once the user has provided enough details."
        )
    )
    async def ui_navigate(
        action: str,
        category_name: str = "",
        task_name: str = "",
        problem_description: str = "",
        additional_notes: str = "",
        service_address: str = "",
        service_lat: str = "",
        service_lng: str = "",
        scheduled_date: str = "",
        scheduled_time: str = "",
        require_photos: bool = True,
        materials_responsibility: str = "",
        accept: str = "",
        request_id: str = "",
        artisan_id: str = "",
        phone: str = "",
        booking_id: str = "",
    ) -> str:
        """Triggers an in-app navigation action."""
        try:
            payload = {
                "category_name": category_name,
                "task_name": task_name,
                "problem_description": problem_description,
                "additional_notes": additional_notes,
                "service_address": service_address,
                "service_lat": service_lat,
                "service_lng": service_lng,
                "scheduled_date": scheduled_date,
                "scheduled_time": scheduled_time,
                "require_photos": require_photos,
                "materials_responsibility": materials_responsibility,
                "accept": accept,
                "request_id": request_id,
                "artisan_id": artisan_id,
                "phone": phone,
                "booking_id": booking_id,
            }
            text = ""
            if action == "create_order_booking":
                text = (
                    "Creating your booking now and dispatching the nearest available artisan. "
                    "Please keep the app open."
                )
            elif action == "dispatch_artisan":
                text = "Dispatching the nearest available artisan now. Please keep the app open."
            elif action == "open_rfq_upload":
                text = (
                    "Opening the photo upload page now. Please add 2-3 clear photos of the work needed."
                )
            elif action == "open_bookings_tab":
                text = "Opening your bookings now."
            elif action == "open_future_bookings":
                text = "Opening your future bookings now."
            elif action == "open_artisan_requests":
                text = "Opening your requests now."
            elif action == "open_artisan_appointments":
                text = "Opening your appointments now."
            elif action == "open_artisan_wallet":
                text = "Opening your wallet now."
            elif action == "accept_latest_request":
                text = "Accepting the latest pending request now."
            elif action == "reject_latest_request":
                text = "Rejecting the latest pending request now."
            elif action == "respond_to_request":
                text = "Updating that request now."
            elif action == "call_assigned_artisan" or action == "call_artisan":
                text = "Calling the assigned artisan now."
            else:
                text = "Working on that now."
            meta = {
                "type": "square15_ui",
                "action": action,
                "payload": payload,
                "text": text,
            }
            await _set_agent_metadata(meta)
            return "ok"
        except Exception as e:
            logger.warning(f"ui_navigate failed: {e}")
            return "error"

    agent = voice.Agent(
        vad=vad,
        stt=openai.STT(model="whisper-1", language="en"),
        llm=openai.LLM(model="gpt-4o-mini", temperature=0.0),
        tts=openai.TTS(model="tts-1", voice="alloy"),
        instructions=_instructions_for_role(caller_role),
    )

    logger.info("🚀 Starting agent session...")
    session = voice.AgentSession(tools=[ui_navigate])

    # Guardrail: never allow internal/tool narration to reach TTS.
    _orig_say = session.say

    async def _say_sanitized(text: str, *args, **kwargs):
        cleaned = _sanitize_spoken_text(text)
        if not cleaned:
            return None
        return await _orig_say(cleaned, *args, **kwargs)

    session.say = _say_sanitized

    await session.start(agent, room=ctx.room)
    logger.info("✅ Agent session started and running!")

    # Listen for app -> agent metadata messages (e.g. booking updates).
    # The Flutter app will set its own participant metadata to JSON:
    #   {"type":"square15_app","action":"speak","payload":{"text":"..."},...}
    last_metadata_by_identity: dict[str, str] = {}

    def on_participant_metadata_changed(participant, old_metadata, new_metadata):
        try:
            if not new_metadata or not str(new_metadata).strip():
                return

            # Ignore agent's own metadata updates.
            try:
                if ctx.room and ctx.room.local_participant and participant.identity == ctx.room.local_participant.identity:
                    return
            except Exception:
                pass

            ident = (getattr(participant, "identity", "") or "").strip()
            if ident:
                if last_metadata_by_identity.get(ident) == new_metadata:
                    return
                last_metadata_by_identity[ident] = new_metadata

            try:
                msg = json.loads(new_metadata)
            except Exception:
                return
            if not isinstance(msg, dict):
                return

            if (msg.get("type") or "").strip() != "square15_app":
                return

            action = (msg.get("action") or "").strip()
            payload = msg.get("payload") if isinstance(msg.get("payload"), dict) else {}

            if action == "speak":
                text = _sanitize_spoken_text(
                    (payload.get("text") or msg.get("text") or "")
                )
                if not text:
                    return
                asyncio.create_task(session.say(text, allow_interruptions=True))
        except Exception as e:
            logger.info(f"metadata handler error (ignored): {e}")

    try:
        ctx.room.on("participant_metadata_changed", on_participant_metadata_changed)
        logger.info("✅ Listening for app metadata (square15_app)")
    except Exception as e:
        logger.warning(f"⚠️ Could not attach metadata listener: {e}")

    try:
        await session.say(
            "Hi, I am Lizzy, how can I help you today?",
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
    build_tag = "2026-01-03-photos-first-no-tool-narration"
    render_commit = (
        os.getenv("RENDER_GIT_COMMIT")
        or os.getenv("RENDER_COMMIT")
        or os.getenv("GIT_COMMIT")
        or ""
    ).strip()
    logger.info(
        "🚀 Starting Square 15 Voice Agent Worker... tag=%s%s",
        build_tag,
        f" commit={render_commit}" if render_commit else "",
    )
    logger.info(
        "🧩 Worker build tag: %s%s",
        build_tag,
        f" (commit={render_commit})" if render_commit else "",
    )
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
