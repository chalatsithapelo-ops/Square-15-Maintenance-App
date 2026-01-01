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
            "You are the Square 15 Voice AI Assistant. "
            f"You are currently speaking to a {role.upper()} user.\n"
        )

        # These rules are written to maximize tool-calling reliability.
        hard_rules = (
            "Hard rules (must follow):\n"
            "- If the user asks you to DO something in the app, you MUST call ui_navigate.\n"
            "- Never say you cannot access the app. The way you act in the app is by calling ui_navigate.\n"
            "- When you are ready to dispatch/accept/reject/call, CALL ui_navigate immediately, then confirm in 1 sentence.\n"
            "- Never get stuck: do not say 'checking availability' unless you are calling ui_navigate in the SAME turn.\n"
            "- Speak naturally (not robotic). Keep it concise (1-3 short sentences).\n"
        )

        client_flow = (
            "Client workflow (dispatch):\n"
            "1) Identify the trade/category from symptoms. If unclear, ask ONE clarifying question.\n"
            "2) Collect the minimum details needed to dispatch: category_name + problem_description.\n"
            "   Location is preferred; if missing, ask ONE question: 'Use your current location or a different address?'\n"
            "3) As soon as you have category + problem_description, you MUST dispatch.\n"
            "   CALL ui_navigate(action='dispatch_artisan' or 'create_order_booking') with whatever fields you know.\n"
            "4) If it sounds like an RFQ (big/complex/needs quote/unclear), ask for 2-3 photos and CALL ui_navigate(action='open_rfq_upload').\n"
            "5) If the user asks to call the assigned artisan, CALL ui_navigate(action='call_assigned_artisan').\n"
            "\nExamples (client):\n"
            "- User: 'Dispatch a plumber, my tap is leaking.'\n"
            "  You: ask location if missing; then CALL ui_navigate(action='dispatch_artisan', category_name='Plumbing', problem_description='Leaking tap', ...).\n"
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
                "materials_responsibility": materials_responsibility,
                "accept": accept,
                "request_id": request_id,
                "artisan_id": artisan_id,
                "phone": phone,
                "booking_id": booking_id,
            }
            text = ""
            if action == "create_order_booking":
                # Don't speak yet - let the app confirm actual booking result
                text = ""
            elif action == "dispatch_artisan":
                # Don't speak yet - let the app confirm actual booking result
                text = ""
            elif action == "open_rfq_upload":
                # Don't speak yet - app will speak before opening upload
                text = ""
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

    session = voice.AgentSession(tools=[ui_navigate])

    # Listen for app->agent requests delivered via participant metadata.
    # The mobile app sends: {"type":"square15_app","action":"speak","payload":{"text":"..."}}
    # so the agent can speak without needing Firestore access.
    _last_spoken_meta_by_identity: dict[str, str] = {}

    def _extract_speak_text(meta_str: str) -> str:
        if not meta_str:
            return ""
        try:
            data = json.loads(meta_str)
        except Exception:
            return ""

        if not isinstance(data, dict):
            return ""
        if data.get("type") != "square15_app" or data.get("action") != "speak":
            return ""

        payload = data.get("payload")
        if isinstance(payload, dict):
            text = payload.get("text")
            if isinstance(text, str) and text.strip():
                return text.strip()

        text = data.get("text")
        if isinstance(text, str) and text.strip():
            return text.strip()

        return ""

    async def _say_from_app(text: str) -> None:
        try:
            await session.say(text, allow_interruptions=True)
            logger.info(f"[ai_meta] spoke_from_app len={len(text)}")
        except Exception as e:
            logger.warning(f"⚠️ Failed to speak app message: {e}")

    def _on_participant_metadata_changed(*args, **kwargs) -> None:
        try:
            participant = args[0] if len(args) > 0 else None
            new_meta = args[2] if len(args) > 2 else None

            identity = (getattr(participant, "identity", "") or "unknown").strip()

            meta_str = ""
            if isinstance(new_meta, str) and new_meta:
                meta_str = new_meta
            else:
                meta_str = getattr(participant, "metadata", "") or ""

            # De-dupe repeated metadata packets.
            if meta_str and _last_spoken_meta_by_identity.get(identity) == meta_str:
                return
            if meta_str:
                _last_spoken_meta_by_identity[identity] = meta_str

            text = _extract_speak_text(meta_str)
            if not text:
                return

            asyncio.create_task(_say_from_app(text))
        except Exception as e:
            logger.warning(f"⚠️ metadata_changed handler failed: {e}")

    try:
        if hasattr(ctx.room, "on"):
            ctx.room.on("participant_metadata_changed", _on_participant_metadata_changed)
            logger.info("✅ Listening for square15_app:speak via participant metadata")
    except Exception as e:
        logger.warning(f"⚠️ Could not attach metadata listener: {e}")

    agent = voice.Agent(
        vad=vad,
        stt=openai.STT(model="whisper-1", language="en"),
        llm=openai.LLM(model="gpt-4o-mini", temperature=0.2),
        tts=openai.TTS(model="tts-1", voice="alloy"),
        instructions=_instructions_for_role(caller_role),
    )

    logger.info("🚀 Starting agent session...")
    await session.start(agent, room=ctx.room)
    logger.info("✅ Agent session started and running!")

    try:
        await session.say(
            "Hi there — thanks for calling Square 15. How can I help you today?",
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
