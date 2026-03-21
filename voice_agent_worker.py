"""
LiveKit Voice Agent Worker - Cloud Deploy

This file is a copy of the app worker script, placed in agent-worker/ so you can
upload/deploy a minimal set of files to GitHub/Render.
"""

# ── Version tag — bump this on every deploy so we can verify Render runs the
# latest code.  Check Render logs for the startup banner.
WORKER_VERSION = "2026-02-26-v5"

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
import aiohttp
from typing import Optional, Dict, Any


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
)
logger = logging.getLogger(__name__)

# Module-level pricing cache — updated on every successful pricing lookup.
# Used as fallback when the backend is unreachable.
_pricing_cache: Optional[str] = None


_FORBIDDEN_SPEECH_PATTERNS = [
    # Tool call narration / internal jargon (including the common typo "nagivation")
    re.compile(r"\bcalling\s+ui\s+na(?:g)?ivation\b", re.IGNORECASE),
    re.compile(r"\bcalling\s+ui_navigate\b", re.IGNORECASE),
    re.compile(r"\bui_navigate\b", re.IGNORECASE),
    re.compile(r"\bsquare15_ui\b", re.IGNORECASE),
    re.compile(r"\bsquare15_app\b", re.IGNORECASE),
    re.compile(r"\bSQUARE15_UI\b", re.IGNORECASE),
    # Prevent agent from saying "loading/opening/opened" phrases when it cannot actually load/see anything
    re.compile(r"\b(?:i\s+am\s+)?loading\s+(?:the\s+)?(?:picture|photo|image)s?\b", re.IGNORECASE),
    re.compile(r"\b(?:let\s+me\s+)?(?:load|check)\s+(?:the\s+)?(?:picture|photo|image)s?\b", re.IGNORECASE),
    re.compile(r"\bopening\s+(?:the\s+)?(?:picture|photo|image)s?\b", re.IGNORECASE),
    re.compile(r"\b(?:i\s+have\s+)?opened\s+(?:the\s+)?(?:picture|photo|image)\s+(?:upload|screen)\b", re.IGNORECASE),
    re.compile(r"\bopening\s+(?:picture|photo|image)\s+upload\b", re.IGNORECASE),
]


def _sanitize_spoken_text(text: str) -> str:
    """Remove internal/tool narration from anything that could be spoken."""
    t = (text or "").strip()
    if not t:
        return ""
    for pat in _FORBIDDEN_SPEECH_PATTERNS:
        if pat.search(t):
            return ""
    # Convert currency amounts to TTS-friendly spoken text
    t = _format_currency_for_speech(t)
    return t


def _format_currency_for_speech(text: str) -> str:
    """Convert South African Rand currency amounts to natural spoken language.
    
    Converts patterns like:
      R1,000,000   → 1 million rand
      R1000000     → 1 million rand
      R1,000       → 1 thousand rand
      R250.50      → 250 rand and 50 cents
      R100         → 100 rand
      R0.50        → 50 cents
    """
    import re as _re

    def _number_to_words(n: float) -> str:
        """Convert a number to a spoken word representation for currency."""
        if n < 0:
            return "negative " + _number_to_words(-n)

        # Handle cents
        whole = int(n)
        cents = round((n - whole) * 100)

        parts = []

        if whole == 0 and cents > 0:
            parts.append(f"{cents} cents")
            return " ".join(parts)

        if whole >= 1_000_000_000:
            billions = whole // 1_000_000_000
            remainder = whole % 1_000_000_000
            parts.append(f"{billions} billion")
            if remainder >= 1_000_000:
                millions = remainder // 1_000_000
                remainder = remainder % 1_000_000
                parts.append(f"{millions} million")
            if remainder >= 1_000:
                thousands = remainder // 1_000
                remainder = remainder % 1_000
                parts.append(f"{thousands} thousand")
            if remainder > 0:
                parts.append(str(remainder))
        elif whole >= 1_000_000:
            millions = whole // 1_000_000
            remainder = whole % 1_000_000
            parts.append(f"{millions} million")
            if remainder >= 1_000:
                thousands = remainder // 1_000
                remainder = remainder % 1_000
                parts.append(f"{thousands} thousand")
            if remainder > 0:
                parts.append(str(remainder))
        elif whole >= 1_000:
            thousands = whole // 1_000
            remainder = whole % 1_000
            parts.append(f"{thousands} thousand")
            if remainder > 0:
                parts.append(str(remainder))
        else:
            parts.append(str(whole))

        result = " ".join(parts) + " rand"
        if cents > 0:
            result += f" and {cents} cents"
        return result

    def _replace_match(m: _re.Match) -> str:
        raw = m.group(1)
        # Remove commas and spaces from the number
        cleaned = raw.replace(",", "").replace(" ", "")
        try:
            value = float(cleaned)
        except ValueError:
            return m.group(0)  # Return original if can't parse
        return _number_to_words(value)

    # Match R followed by digits (with optional commas, spaces, decimal)
    # Handles: R1,000,000  R1000000  R250.50  R100  R0.50
    result = _re.sub(
        r'R\s*([\d,]+(?:\.\d{1,2})?)',
        _replace_match,
        text
    )
    return result


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


# Backend API client for Square15
class BackendAPIClient:
    """Client for calling Square15 backend action endpoints."""

    def __init__(self, base_url: str, firebase_token: Optional[str] = None, session_id: Optional[str] = None, session_nonce: Optional[str] = None):
        self.base_url = base_url.rstrip('/')
        self.firebase_token = firebase_token
        self.session_id = session_id
        self.session_nonce = session_nonce
        self.timeout = aiohttp.ClientTimeout(total=30)

    def _get_headers(self) -> Dict[str, str]:
        headers = {
            'Content-Type': 'application/json',
        }
        if self.firebase_token:
            headers['Authorization'] = f'Bearer {self.firebase_token}'
        return headers

    def _get_context(self) -> Dict[str, Any]:
        """Build context object for session binding."""
        ctx = {}
        if self.session_id:
            ctx['session_id'] = self.session_id
        if self.session_nonce:
            ctx['session_nonce'] = self.session_nonce
        return ctx

    async def get_booking_status(self, booking_id: str) -> Dict[str, Any]:
        """Get booking status from backend."""
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            payload = {
                'action': 'get_booking_status',
                'payload': {'booking_id': booking_id},
                'context': self._get_context(),
            }
            async with session.post(
                f'{self.base_url}/api/action/execute',
                json=payload,
                headers=self._get_headers()
            ) as resp:
                return await resp.json()

    async def list_user_bookings(self, status: Optional[str] = None, limit: int = 10) -> Dict[str, Any]:
        """List user's bookings."""
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            payload = {
                'action': 'list_user_bookings',
                'payload': {'status': status or '', 'limit': limit},
                'context': self._get_context(),
            }
            async with session.post(
                f'{self.base_url}/api/action/execute',
                json=payload,
                headers=self._get_headers()
            ) as resp:
                return await resp.json()

    async def explain_rfq_quote(self, booking_id: str) -> Dict[str, Any]:
        """Explain RFQ quote details."""
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            payload = {
                'action': 'explain_rfq_quote',
                'payload': {'booking_id': booking_id},
                'context': self._get_context(),
            }
            async with session.post(
                f'{self.base_url}/api/action/execute',
                json=payload,
                headers=self._get_headers()
            ) as resp:
                return await resp.json()

    async def get_payment_status(self, booking_id: str) -> Dict[str, Any]:
        """Get payment status."""
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            payload = {
                'action': 'get_payment_status',
                'payload': {'tasks_management_id': booking_id},
                'context': self._get_context(),
            }
            async with session.post(
                f'{self.base_url}/api/action/execute',
                json=payload,
                headers=self._get_headers()
            ) as resp:
                return await resp.json()

    async def call_backend_action(self, action: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        """Generic action executor via /api/action/execute."""
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            body = {
                'action': action,
                'payload': payload,
                'context': self._get_context(),
            }
            async with session.post(
                f'{self.base_url}/api/action/execute',
                json=body,
                headers=self._get_headers()
            ) as resp:
                return await resp.json()

    async def propose_action(self, action: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        """Propose an action (Phase 1 proposal)."""
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            body = {
                'action': action,
                'payload': payload,
                'context': self._get_context(),
            }
            async with session.post(
                f'{self.base_url}/api/action/propose',
                json=body,
                headers=self._get_headers()
            ) as resp:
                return await resp.json()

    async def confirm_action(self, proposal_id: str) -> Dict[str, Any]:
        """Confirm a proposed action (Phase 1 confirmation)."""
        async with aiohttp.ClientSession(timeout=self.timeout) as session:
            body = {'proposalId': proposal_id}
            async with session.post(
                f'{self.base_url}/api/action/confirm',
                json=body,
                headers=self._get_headers()
            ) as resp:
                return await resp.json()

    async def lookup_service_pricing(self, category_name: str = "", task_name: str = "", query: str = "") -> Dict[str, Any]:
        """Look up service pricing from the backend."""
        return await self.call_backend_action('lookup_service_pricing', {
            'category_name': category_name,
            'task_name': task_name,
            'query': query,
        })


async def entrypoint(ctx: JobContext):
    room_name = ctx.room.name
    logger.info(f"🎯 New job received for room: {room_name}  [worker v{WORKER_VERSION}]")

    openai_key = os.getenv("OPENAI_API_KEY")
    if not openai_key:
        logger.error("❌ OPENAI_API_KEY not set!")
        return

    # Backend API configuration
    backend_url = os.getenv("BACKEND_API_URL", "https://square15-livekit-backend.onrender.com")
    logger.info(f"📡 Backend API URL: {backend_url}")

    # Initialize backend client (will be updated with token/session after voice start)
    backend_client = None
    firebase_token = None
    session_id = None
    session_nonce = None
    # Bookings sent from the app context (fallback when backend_client is not yet initialized)
    app_context_bookings = []
    app_context_user_id = ""

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
    # Tuned for low-latency conversational feel:
    #   min_silence_duration: 0.25s (default 0.55) – detect end-of-speech faster
    #   prefix_padding_duration: 0.3s (default 0.5) – less audio buffering
    #   activation_threshold: 0.4 (default 0.5) – slightly more sensitive
    vad = silero.VAD.load(
        min_silence_duration=0.25,
        prefix_padding_duration=0.3,
        activation_threshold=0.4,
    )

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

        base = (
            f"You are Lizzy, the Square 15 Voice AI Assistant, speaking to a {role.upper()} user.\n\n"
            "RULES:\n"
            "- Greet once, then just help. Never repeat your introduction.\n"
            "- When user asks to DO something, CALL the right tool immediately. Do NOT describe what you would do — just do it.\n"
            "- NEVER say 'I cannot access', 'I am unable to', 'I don't have access to', or 'I need you to be authenticated'. ALWAYS try calling the relevant tool.\n"
            "- BACKEND tools for data: get_booking_status, list_my_bookings, explain_quote, check_payment, get_wallet_balance, get_messages, get_case_status.\n"
            "- BACKEND tools for ACTIONS: cancel_booking, reschedule_booking, send_message_to_artisan, send_message_to_client, send_message_to_admin, mark_booking_in_progress, artisan_cancel_and_reassign, submit_rating, submit_complaint. These tools EXECUTE real actions on the backend — use them, NOT ui_navigate.\n"
            "- lookup_service_pricing for pricing: when user asks 'how much is...', 'what's the price for...', call lookup_service_pricing.\n"
            "- ui_navigate ONLY for opening screens/navigation: open_bookings_tab, open_future_bookings, open_wallet, open_profile, open_settings, open_notifications, open_calendar, open_help, open_support, go_home, go_back, close_window, create_order_booking, call_assigned_artisan.\n"
            "- NEVER use ui_navigate for cancel_booking, reschedule_booking, send_message_to_artisan, send_message_to_client, send_message_to_admin, mark_booking_in_progress, artisan_cancel_and_reassign. Use the dedicated tools instead.\n"
            "- NEVER narrate tool calls. Never say JSON, function names, or metadata.\n"
            "- NEVER claim you opened/loaded pictures or images.\n"
            "- NEVER claim you opened a map or showed a location. There is no map feature.\n"
            "- Speak naturally, 1-3 short sentences. Be concise.\n"
            "- CURRENCY: When speaking amounts, say the full words. Say 'one million rand' NOT 'R1000000'. "
            "Say 'five hundred rand' NOT 'R500'. Say 'one thousand five hundred rand and fifty cents' NOT 'R1500.50'. "
            "NEVER say the letter 'R' before a number. Always use 'rand' after the amount.\n"
            "- If user says 'now'/'asap'/'urgent', use scheduled_date='now', scheduled_time='now'.\n"
            "- Date format: YYYY-MM-DD. Time format: HH:MM.\n"
            "- If user refers to a booking by price, call list_my_bookings first to find it.\n"
            "\n"
            "BOOKING LOOKUP (CRITICAL — MUST USE TOOLS):\n"
            "- When user asks about a booking, 'where is my artisan/plumber?', 'what's the status of my booking?', or similar:\n"
            "  1. FIRST call list_my_bookings() to get their bookings.\n"
            "  2. Find the relevant booking from the results (match by category, artisan, date, or pick the most recent active one).\n"
            "  3. THEN call get_booking_status(booking_id) with the relevant booking ID to get full details.\n"
            "  4. Tell the user the booking status, artisan name, and any relevant info.\n"
            "- NEVER say you 'can't access bookings' or 'unable to retrieve'. ALWAYS call list_my_bookings first. Even if there's an error, try the tool.\n"
            "\n"
            "MESSAGING & CHAT (IMPORTANT — USE BACKEND TOOLS, NOT ui_navigate):\n"
            "- 'Open chat' / 'open messages' / 'contact support' → call ui_navigate(action='open_support')\n"
            "- 'Send message to artisan' / 'tell artisan ...' → call send_message_to_artisan(booking_id, message). Get booking_id from list_my_bookings if needed. This SENDS the message via the backend.\n"
            "- 'Send message to client' / 'tell client ...' / 'message the client' → call send_message_to_client(booking_id, message). Get booking_id from list_my_bookings if needed. This SENDS the message via the backend.\n"
            "- 'Contact admin' / 'send message to support' → call send_message_to_admin(message, subject). This SENDS the message via the backend.\n"
            "- 'Show messages' / 'read messages for booking' → call get_messages(booking_id)\n"
            "\n"
            "SUPPORT CASES:\n"
            "- 'Show my cases' / 'do I have open tickets?' → call list_my_cases(state='open') or list_my_cases() for all\n"
            "- 'Reply to case' / 'follow up on my ticket' → call reply_to_case(case_id, message)\n"
            "- 'Check case status' → call get_case_status(case_id)\n"
            "- When a user has an issue and wants admin help, first create a case with send_message_to_admin(message, subject).\n"
            "- If they want to follow up, use reply_to_case with the case_id.\n"
            "\n"
            "BOOKING MANAGEMENT (CRITICAL — USE DEDICATED TOOLS, NOT ui_navigate):\n"
            "- When user asks to cancel, reschedule, check status, or do anything with a booking:\n"
            "  1. If they don't give a booking ID, call list_my_bookings() first to find it.\n"
            "  2. Then CALL the specific BACKEND tool — these EXECUTE the action:\n"
            "- Cancel: cancel_booking(booking_id, reason) — actually cancels the booking on the server\n"
            "- Reschedule: reschedule_booking(booking_id, scheduled_date, scheduled_time) — actually reschedules on the server\n"
            "- Check status: get_booking_status(booking_id)\n"
            "- Call artisan: ui_navigate(action='call_assigned_artisan', booking_id=...)\n"
            "- Send message to artisan: send_message_to_artisan(booking_id, message) — actually sends the message\n"
            "- IMPORTANT: NEVER use ui_navigate for cancel, reschedule, or messaging. Those only open screens. Use the dedicated tools to execute the action.\n"
            "\n"
            "PRICING ENQUIRIES (CRITICAL — MUST USE TOOL):\n"
            "- When user asks how much a service costs, MUST call lookup_service_pricing. Do NOT answer without calling this tool.\n"
            "- Pass query with the service name (e.g. query='plumbing', query='unblock toilet', query='painting').\n"
            "- The tool ALWAYS returns pricing data. Read back the prices from the results.\n"
            "- If cost is null for a service, say 'This service requires a quote from an artisan'.\n"
            "- NEVER guess or make up prices. ALWAYS call lookup_service_pricing.\n"
            "\n"
            "BOOKING CREATION (IMPORTANT):\n"
            "- To create a new booking, ALWAYS use ui_navigate with action='create_order_booking'.\n"
            "- Provide: category_name, problem_description, and optionally scheduled_date, scheduled_time, service_address.\n"
            "- Do NOT use create_booking tool. ONLY use ui_navigate(action='create_order_booking').\n"
            "- After calling ui_navigate, say 'I am processing your booking now, please keep the app open.' Do NOT say an artisan has been dispatched until confirmed.\n"
            "- NEVER open photo upload, map, or any other screen during booking creation. The app handles everything.\n"
            "- Do NOT use open_map or show_location actions. They do not exist.\n"
            "\n"
            "SCREEN AWARENESS & APP CONTROL (IMPORTANT):\n"
            "- You can see what screen the user is on and what actions are available.\n"
            "- When user asks 'what's on my screen?', 'where am I?', 'what can I do here?' → call get_current_screen()\n"
            "- When user asks 'analyze this', 'explain this page', 'what does this mean?' → call analyze_screen()\n"
            "- When user asks 'what can you do?', 'what features are available?' → call list_app_features()\n"
            "- You control the app completely: navigate to any screen, execute any action, check any data.\n"
            "- Think of yourself as the user's personal app assistant — they talk, you do.\n"
            "\n"
            "SERVICE AREA RESTRICTIONS:\n"
            "- Square 15 currently operates in specific service areas only (phased launch).\n"
            "- If a booking is rejected because the user's location is outside our service area, explain politely: "
            "'Sorry, Square 15 is not yet available in your area. We are currently serving select areas and expanding soon.'\n"
            "- Do NOT promise service in areas we don't cover yet.\n"
            "- The app automatically checks the user's location against active service areas.\n"
        )

        if role == "artisan":
            base += (
                "\nARTISAN ACTIONS:\n"
                "- Accept job → ui_navigate(action='accept_latest_request')\n"
                "- Reject job → ui_navigate(action='reject_latest_request')\n"
                "- Start job → mark_booking_in_progress(booking_id)\n"
                "- Cancel+reassign → artisan_cancel_and_reassign(booking_id, reason)\n"
                "  IMPORTANT: Before calling artisan_cancel_and_reassign, you MUST ask the artisan to confirm. "
                "Say something like 'Are you sure you want to cancel this job and have it reassigned to another artisan?' "
                "Only proceed if the artisan explicitly says yes.\n"
                "- Artisan screens: open_artisan_requests, open_artisan_appointments, open_artisan_wallet, open_schedule.\n"
                "- Do not dispatch artisans while talking to an artisan.\n"
            )
        else:
            base += (
                "\nCLIENT ACTIONS:\n"
                "- Create booking: collect category + problem, then call ui_navigate(action='create_order_booking') with category_name and problem_description. The app handles pricing, RFQ creation, and artisan dispatch automatically.\n"
                "- Cancel: cancel_booking(booking_id, reason). Reschedule: reschedule_booking(booking_id, date, time).\n"
                "- Call artisan → ui_navigate(action='call_assigned_artisan', booking_id)\n"
                "- Future bookings → ui_navigate(action='open_future_bookings')\n"
            )

        return base

    @llm.function_tool(
        description=(
            "Send a UI navigation command to the Square 15 mobile app. "
            "Use ONLY for navigation and screen-opening actions. "
            "Supported actions: create_order_booking, dispatch_artisan, "
            "open_bookings_tab, open_future_bookings, open_artisan_requests, open_artisan_appointments, "
            "open_artisan_wallet, accept_latest_request, reject_latest_request, respond_to_request, "
            "call_assigned_artisan, "
            "open_notifications, open_profile, open_settings, open_support, open_wallet, "
            "open_calendar, open_help, go_home, go_back, close_window, close_dialog, dismiss. "
            "DO NOT use for cancel_booking, reschedule_booking, send_message_to_artisan, "
            "send_message_to_admin, mark_booking_in_progress, artisan_cancel_and_reassign — "
            "use the dedicated action tools instead."
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
            # ── Redirect action calls to dedicated backend tools ──
            # If the LLM accidentally calls ui_navigate for actions that should use
            # the dedicated backend tools, redirect to those tools instead.
            if action in ("cancel_booking",) and booking_id:
                logger.info(f"↪ Redirecting ui_navigate({action}) → cancel_booking tool")
                return await cancel_booking(booking_id=booking_id, reason=additional_notes or "User requested cancellation")
            if action in ("reschedule_booking",) and booking_id:
                logger.info(f"↪ Redirecting ui_navigate({action}) → reschedule_booking tool")
                return await reschedule_booking(booking_id=booking_id, scheduled_date=scheduled_date, scheduled_time=scheduled_time)
            if action in ("mark_booking_in_progress",) and booking_id:
                logger.info(f"↪ Redirecting ui_navigate({action}) → mark_booking_in_progress tool")
                return await mark_booking_in_progress(booking_id=booking_id)
            if action in ("artisan_cancel_and_reassign", "reassign_booking") and booking_id:
                logger.info(f"↪ Redirecting ui_navigate({action}) → artisan_cancel_and_reassign tool")
                return await artisan_cancel_and_reassign(booking_id=booking_id, reason=additional_notes or "Reassignment requested")

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
                text = (
                    "Processing your booking request now. Please keep the app open."
                )
            elif action == "dispatch_artisan":
                text = (
                    "Processing your booking request now. Please keep the app open."
                )
            elif action == "open_rfq_upload":
                text = (
                    "Please upload 3 clear photos of the work needed in the photo upload screen."
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
            elif action == "get_booking_status":
                text = "Checking that booking status now."
            elif action == "reschedule_booking":
                text = "Rescheduling that booking now. Please confirm the new time in the app." 
            elif action == "cancel_booking":
                text = "Cancelling that booking now. Please confirm in the app." 
            elif action == "reassign_booking":
                text = "Reassigning that booking now. If no nearby artisan is available, an admin will assign one."
            elif action == "mark_booking_in_progress":
                text = "Marking that booking as in progress now."
            elif action == "artisan_cancel_and_reassign":
                text = "Cancelling and reassigning now. If no nearby artisan is available, an admin will assign one."
            elif action == "open_notifications":
                text = "Opening your notifications."
            elif action == "open_profile":
                text = "Opening your profile."
            elif action == "open_settings":
                text = "Opening settings."
            elif action in ("open_support", "open_chat_support"):
                text = "Opening support chat."
            elif action in ("open_wallet", "open_user_wallet"):
                text = "Opening your wallet."
            elif action in ("open_calendar", "open_artisan_calendar"):
                text = "Opening your calendar."
            elif action in ("open_map", "show_location"):
                text = "I don't have a map feature available right now."
            elif action in ("open_help", "open_faq"):
                text = "Here are some helpful tips."
            elif action in ("go_home", "open_dashboard"):
                text = "Going to the home screen."
            elif action in ("go_back", "navigate_back"):
                text = "Going back."
            elif action in ("close_window", "close_dialog", "dismiss"):
                text = "Closing that now."
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

    # ── Helper: retry credential scan before giving up ──
    async def _ensure_backend_or_retry() -> bool:
        """Last-ditch attempt to initialize backend_client if not set."""
        nonlocal backend_client
        if backend_client:
            return True
        logger.info("🔄 _ensure_backend_or_retry: backend_client is None, scanning...")
        # Try multiple scans with increasing waits
        for attempt in range(5):
            _scan_participants_for_credentials()
            if backend_client:
                logger.info(f"✅ _ensure_backend_or_retry: got client on attempt {attempt + 1}")
                return True
            wait_time = 1.0 + attempt * 0.5  # 1.0, 1.5, 2.0, 2.5, 3.0
            logger.info(f"⏳ _ensure_backend_or_retry: attempt {attempt + 1}/5 failed, waiting {wait_time}s...")
            await asyncio.sleep(wait_time)
        _scan_participants_for_credentials()
        if backend_client:
            logger.info("✅ _ensure_backend_or_retry: got client on final scan")
            return True
        logger.warning("❌ _ensure_backend_or_retry: FAILED after 5 attempts — no firebase_token found in any participant metadata")
        return False

    _CONNECTION_RETRY_MSG = "I'm still connecting to your account. Please try again in a moment."

    # Phase 2: Read-only backend tools
    @llm.function_tool(
        description=(
            "Get the current status of a booking by booking ID. "
            "Returns status, scheduled time, artisan details, and payment info. "
            "Use this when user asks 'What's my booking status?' or 'Where is my artisan?'"
        )
    )
    async def get_booking_status(booking_id: str) -> str:
        """Get booking status from backend API."""
        nonlocal backend_client, app_context_bookings
        logger.info(f"📋 get_booking_status called: booking_id={booking_id}, backend_client={'SET' if backend_client else 'NONE'}, app_bookings={len(app_context_bookings)}")
        if not backend_client:
            # Fallback: check app context bookings if available
            if app_context_bookings:
                for b in app_context_bookings:
                    if b.get('booking_id') == booking_id:
                        status = b.get('status', 'unknown')
                        category = b.get('category', 'service')
                        artisan_name = b.get('artisan_name', '')
                        date = b.get('scheduled_date', '')
                        time = b.get('scheduled_time', '')
                        price = b.get('price', '')
                        desc = b.get('description', '')
                        response = f"Booking {booking_id} for {category}: Status is {status}."
                        if date and time:
                            response += f" Scheduled for {date} at {time}."
                        elif date:
                            response += f" Scheduled for {date}."
                        if artisan_name:
                            response += f" Artisan: {artisan_name}."
                        if price:
                            response += f" Price: R{price}."
                        if desc:
                            response += f" Description: {desc}."
                        return response
                return f"I couldn't find booking {booking_id} in your recent bookings."
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            result = await backend_client.get_booking_status(booking_id)
            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'booking_not_found':
                    return f"I couldn't find booking {booking_id}. Please check the booking ID."
                elif error == 'forbidden':
                    return "You don't have permission to view that booking."
                else:
                    return f"There was an issue checking the booking: {error}"

            data = result.get('data', result.get('result', {}))
            status = data.get('status', 'unknown')
            category = data.get('category_name', 'service')
            problem = data.get('problem_description', '')
            scheduled_date = data.get('scheduled_date', '')
            scheduled_time = data.get('scheduled_time', '')
            artisan_confirmed = data.get('artisan_confirmed', '')
            price = data.get('total_price', '')
            address = data.get('service_address', '')
            rfq_no = data.get('rfq_no', '')
            rfq_status = data.get('rfq_status', '')
            order_type = data.get('order_type', '')

            response = f"Booking {booking_id} for {category}: Status is {status}."
            if problem:
                response += f" Description: {problem}."
            if scheduled_date and scheduled_time:
                response += f" Scheduled for {scheduled_date} at {scheduled_time}."
            elif scheduled_date:
                response += f" Scheduled for {scheduled_date}."
            if price:
                response += f" Price: R{price}."
            if rfq_no:
                response += f" RFQ #{rfq_no}, RFQ status: {rfq_status}."
            if artisan_confirmed:
                response += f" Artisan confirmation: {artisan_confirmed}."
            if address:
                response += f" Location: {address}."

            artisan = data.get('artisan')
            if artisan and isinstance(artisan, dict):
                name = artisan.get('name', '')
                phone = artisan.get('phone', '')
                trade = artisan.get('trade', '')
                if name:
                    response += f" Artisan: {name}."
                if trade:
                    response += f" Trade: {trade}."
                if phone:
                    response += f" Contact: {phone}."

            return response
        except Exception as e:
            logger.error(f"get_booking_status error: {e}", exc_info=True)
            return "Sorry, I had trouble checking that booking. Please try again."

    @llm.function_tool(
        description=(
            "List the user's recent bookings. Optionally filter by status (e.g., 'pending_assignment', 'in_progress', 'completed'). "
            "Returns booking IDs, categories, statuses, dates, prices, order numbers and RFQ numbers. "
            "Use this when user asks 'Show my bookings', 'What bookings do I have?', "
            "'Find my R67000 booking', or 'Which booking costs...' — then match by price/amount from the results."
        )
    )
    async def list_my_bookings(status: str = "", limit: int = 10) -> str:
        """List user's bookings from backend API."""
        nonlocal backend_client, app_context_bookings
        logger.info(f"📋 list_my_bookings called: status={status!r}, limit={limit}, backend_client={'SET' if backend_client else 'NONE'}, app_bookings={len(app_context_bookings)}")
        if not backend_client:
            # Fallback: use app context bookings if available
            if app_context_bookings:
                filtered = app_context_bookings
                if status:
                    filtered = [b for b in filtered if b.get('status', '').lower() == status.lower()]
                count = len(filtered)
                if count == 0:
                    return "You don't have any bookings" + (f" with status {status}" if status else "") + "."
                response = f"You have {count} booking" + ("s" if count > 1 else "") + ".\n"
                for i, b in enumerate(filtered[:limit], 1):
                    bid = b.get('booking_id', 'unknown')
                    bstatus = b.get('status', 'unknown')
                    category = b.get('category', 'service')
                    artisan = b.get('artisan_name', '')
                    date = b.get('scheduled_date', '')
                    time = b.get('scheduled_time', '')
                    price = b.get('price', '')
                    response += f"{i}. {category} booking {bid}: {bstatus}"
                    if artisan:
                        response += f", artisan: {artisan}"
                    if price:
                        response += f", price R{price}"
                    if date and time:
                        response += f", scheduled {date} at {time}"
                    elif date:
                        response += f", scheduled {date}"
                    response += ".\n"
                return response.strip()
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            logger.info(f"📡 Calling backend list_user_bookings (status={status!r}, limit={min(limit, 10)})")
            result = await backend_client.list_user_bookings(status=status or None, limit=min(limit, 10))
            logger.info(f"📡 Backend response: ok={result.get('ok')}, success={result.get('success')}, error={result.get('error', 'none')}")
            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                logger.warning(f"❌ list_my_bookings backend error: {error}")
                return f"There was an issue getting your bookings: {error}"

            data = result.get('data', result.get('result', {}))
            bookings = data.get('bookings', [])
            count = len(bookings)

            if count == 0:
                return "You don't have any bookings" + (f" with status {status}" if status else "") + "."

            response = f"You have {count} booking" + ("s" if count > 1 else "") + ".\n"
            for i, booking in enumerate(bookings[:10], 1):
                booking_id = booking.get('booking_id', 'unknown')
                booking_status = booking.get('status', 'unknown')
                category = booking.get('category_name', 'service')
                problem = booking.get('problem_description', '')
                date = booking.get('scheduled_date', '')
                time = booking.get('scheduled_time', '')
                price = booking.get('total_price', '')
                rfq_no = booking.get('rfq_no', '')
                order_no = booking.get('order_number', '')
                order_type = booking.get('order_type', '')
                rfq_status = booking.get('rfq_status', '')
                response += f"{i}. {category} booking {booking_id}: {booking_status}"
                if problem:
                    response += f" — {problem}"
                if price:
                    response += f", price R{price}"
                if rfq_no:
                    response += f", RFQ #{rfq_no}"
                if order_no:
                    response += f", order #{order_no}"
                if rfq_status:
                    response += f", RFQ status: {rfq_status}"
                if date and time:
                    response += f", scheduled {date} at {time}"
                elif date:
                    response += f", scheduled {date}"
                response += ".\n"

            return response.strip()
        except Exception as e:
            logger.error(f"list_my_bookings error: {e}", exc_info=True)
            return "Sorry, I had trouble getting your bookings. Please try again."

    @llm.function_tool(
        description=(
            "Get analytics and summary of all bookings/requests in the system. "
            "Returns counts by status, identifies urgent bookings, and gives intelligent insights. "
            "Use this when user asks things like 'How many open requests?', 'What's the system status?', "
            "'Any urgent bookings?', 'Give me a summary', 'How many pending jobs?', "
            "'What's the overview?', or 'Analyze the data'."
        )
    )
    async def get_booking_analytics() -> str:
        """Get analytics summary from backend API."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            result = await backend_client.call_backend_action("get_booking_analytics", {})
            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"There was an issue getting analytics: {error}"

            data = result.get('data', result.get('result', {}))
            total = data.get('total_bookings', 0)
            by_status = data.get('by_status', {})
            urgent = data.get('urgent_bookings', [])
            recent = data.get('recent_bookings', [])

            response = f"Here's your system overview. You have {total} total bookings. "

            if by_status:
                status_parts = []
                for status, count in by_status.items():
                    label = status.replace('_', ' ')
                    status_parts.append(f"{count} {label}")
                response += "Breakdown: " + ", ".join(status_parts) + ". "

            if urgent:
                response += f"There {'is' if len(urgent) == 1 else 'are'} {len(urgent)} urgent booking{'s' if len(urgent) != 1 else ''}. "
                for u in urgent[:3]:
                    name = u.get('client_name', 'a client')
                    category = u.get('category_name', 'service')
                    response += f"Urgent {category} request from {name}. "

            if recent:
                response += f"Most recent: "
                for r in recent[:2]:
                    category = r.get('category_name', 'service')
                    status = r.get('status', 'unknown').replace('_', ' ')
                    response += f"{category} booking, status {status}. "

            return response.strip()
        except Exception as e:
            logger.error(f"get_booking_analytics error: {e}", exc_info=True)
            return "Sorry, I had trouble getting the analytics. Please try again."

    @llm.function_tool(
        description=(
            "Explain the details of an RFQ quote, scope of work, or booking details. "
            "Accepts either a booking_id or an RFQ number (e.g., 'RFQ-BE6A011A'). "
            "Use this when user asks 'Explain my quote', 'What's the scope of work for RFQ-...', "
            "'What's the quote for my RFQ?', or 'Tell me about RFQ-...'"
        )
    )
    async def explain_quote(booking_id: str) -> str:
        """Explain RFQ quote from backend API."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            result = await backend_client.explain_rfq_quote(booking_id)
            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'booking_not_found':
                    return f"I couldn't find booking {booking_id}."
                elif error == 'not_an_rfq':
                    return "That booking is not an RFQ request."
                else:
                    return f"There was an issue: {error}"

            data = result.get('data', result.get('result', {}))
            quote_status = data.get('quote_status', 'pending')
            explanation = data.get('explanation', '')
            quoted_price = data.get('quoted_price', '')
            quote_details = data.get('quote_details', '')
            scope_of_work = data.get('scope_of_work', '')
            problem_desc = data.get('problem_description', '')
            rfq_no = data.get('rfq_no', '')
            category = data.get('category_name', '')
            rfq_status = data.get('rfq_status', '')

            response = ''
            if rfq_no:
                response += f"RFQ number: {rfq_no}. "
            if category:
                response += f"Category: {category}. "
            if rfq_status:
                response += f"RFQ status: {rfq_status}. "
            if scope_of_work:
                response += f"Scope of work: {scope_of_work}. "
            elif problem_desc:
                response += f"Description: {problem_desc}. "
            if explanation:
                response += explanation
            elif not response:
                response = f"Quote status: {quote_status}."
            if quoted_price:
                response += f" Quoted price: R{quoted_price}."
            if quote_details:
                response += f" Details: {quote_details}."

            return response.strip()
        except Exception as e:
            logger.error(f"explain_quote error: {e}", exc_info=True)
            return "Sorry, I had trouble getting that quote. Please try again."

    @llm.function_tool(
        description=(
            "Check the payment status for a booking. "
            "Use this when user asks 'Did I pay?' or 'What's the payment status?'"
        )
    )
    async def check_payment(booking_id: str) -> str:
        """Check payment status from backend API."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            result = await backend_client.get_payment_status(booking_id)
            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"There was an issue checking payment: {error}"

            data = result.get('data', result.get('result', {}))
            payment_status = data.get('payment_status', 'unknown')
            message = data.get('message', '')
            transactions = data.get('transactions', [])

            if payment_status == 'not_found':
                return "I couldn't find any payment records for that booking."

            response = message or f"Payment status: {payment_status}."
            if transactions and len(transactions) > 0:
                latest = transactions[0]
                amount = latest.get('amount', '')
                tx_status = latest.get('status', '')
                if amount:
                    response += f" Latest transaction: {amount}, status: {tx_status}."

            return response
        except Exception as e:
            logger.error(f"check_payment error: {e}", exc_info=True)
            return "Sorry, I had trouble checking payment. Please try again."

    @llm.function_tool(
        description=(
            "Look up the price of a service. Use this when the user asks "
            "'how much is...', 'what's the price for...', 'how much do you charge for...', "
            "'what does ... cost?'. Provide category_name (e.g. 'plumbing', 'electrical') "
            "and/or task_name (e.g. 'unblock toilet', 'install geyser'). "
            "You can also pass a general query string."
        )
    )
    async def lookup_service_pricing(
        category_name: str = "",
        task_name: str = "",
        query: str = ""
    ) -> str:
        """Look up service pricing from the backend (public endpoint, no auth needed)."""
        search_q = query or f"{category_name} {task_name}".strip()
        if not search_q:
            search_q = "all"

        logger.info(f"🔍 lookup_service_pricing called: category={category_name}, task={task_name}, query={search_q}")

        try:
            import urllib.parse
            encoded_q = urllib.parse.quote(search_q)
            url = f"{backend_url}/api/test-pricing?q={encoded_q}"
            logger.info(f"🔍 Calling public pricing endpoint: {url}")

            async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=25)) as http_session:
                async with http_session.get(url) as resp:
                    logger.info(f"🔍 Pricing response status: {resp.status}")
                    if resp.status != 200:
                        body_text = await resp.text()
                        logger.warning(f"🔍 Pricing endpoint returned {resp.status}: {body_text[:200]}")
                        return f"Sorry, I couldn't look up pricing right now. The service returned an error. Please try again."
                    result = await resp.json()

            logger.info(f"🔍 Pricing result ok={result.get('ok')}, matched={result.get('matched')}")

            if not result.get('ok'):
                return "Sorry, I couldn't look up pricing right now. Please try again in a moment."

            services = result.get('services', [])
            message = result.get('message', '')

            if not services:
                return message or "I couldn't find any services matching that description. Could you try a different term like 'plumbing', 'painting', or 'bathroom'?"

            # Format the pricing list for the agent to speak
            lines = []
            current_category = None
            for svc in services[:15]:  # Limit to 15 for voice readability
                cat = svc.get('category_name', 'Other')
                name = svc.get('name', 'Unknown')
                cost_str = svc.get('cost_formatted', 'Quote on request')

                if cat != current_category:
                    current_category = cat
                    if cat:
                        lines.append(f"\n{cat}:")

                lines.append(f"  - {name}: {cost_str}")

            total = result.get('matched', len(services))
            header = f"Found {total} service(s)."
            if total > 15:
                header += " Here are the first 15:"

            response = header + "\n" + "\n".join(lines)
            logger.info(f"🔍 Returning pricing with {total} services to agent")
            # Cache the successful response for fallback use
            global _pricing_cache
            _pricing_cache = response
            return response
        except Exception as e:
            logger.error(f"lookup_service_pricing error: {e}", exc_info=True)
            # Use cached pricing from a previous successful call if available
            if _pricing_cache:
                logger.info("🔍 Using cached pricing as fallback")
                return "I'm having a brief connection issue, but here are our prices from my recent records:\n" + _pricing_cache
            # Absolute last resort — generic message (should rarely happen)
            return (
                "I'm having a temporary connection issue retrieving our latest prices. "
                "Please check the services section in the app for current pricing, or try asking me again in a moment."
            )

    # Phase 1: Write operations with propose/confirm
    @llm.function_tool(
        description=(
            "Create a new order booking and dispatch an artisan. "
            "Requires: category_name, problem_description. "
            "Optional: scheduled_date, scheduled_time, service_address. "
            "This uses the propose-confirm workflow for safety."
        )
    )
    async def create_booking(
        category_name: str,
        problem_description: str,
        scheduled_date: str = "",
        scheduled_time: str = "",
        service_address: str = "",
        is_rfq: str = "no"
    ) -> str:
        """Create a booking using backend propose/confirm workflow."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            # Phase 1: Propose the action
            payload = {
                'category_name': category_name,
                'problem_description': problem_description,
                'scheduled_date': scheduled_date or '',
                'scheduled_time': scheduled_time or '',
                'service_address': service_address or '',
                'is_rfq': is_rfq,
            }
            proposal_result = await backend_client.propose_action('create_order_booking', payload)

            if not proposal_result.get('success'):
                error = proposal_result.get('error', 'unknown_error')
                return f"I couldn't create the booking proposal: {error}"

            proposal_id = proposal_result.get('proposalId')
            if not proposal_id:
                return "Booking proposal created but I didn't get a proposal ID. Please try again."

            # Phase 1: Confirm the action
            confirm_result = await backend_client.confirm_action(proposal_id)

            if not confirm_result.get('success'):
                error = confirm_result.get('error', 'unknown_error')
                return f"Booking proposed but confirmation failed: {error}"

            result_data = confirm_result.get('result', {})
            booking_id = result_data.get('booking_id') or result_data.get('bookingId')
            is_rfq_flag = result_data.get('is_rfq') or result_data.get('isRFQ')

            if is_rfq_flag:
                return f"Your RFQ request has been submitted (booking {booking_id}). Admin will review and provide a quote shortly."
            else:
                return f"Booking {booking_id} created successfully! Dispatching the nearest available artisan now. You'll be notified once an artisan accepts."

        except Exception as e:
            logger.error(f"create_booking error: {e}", exc_info=True)
            return "Sorry, I had trouble creating the booking. Please try again or use the app directly."

    # =========================================
    # Phase 3: Messaging Tools
    # =========================================

    @llm.function_tool(
        description=(
            "Send a message to the artisan assigned to a booking. "
            "Use this when the user wants to contact their artisan (ask about ETA, location, confirm details, etc.). "
            "Requires: booking_id, message."
        )
    )
    async def send_message_to_artisan(
        booking_id: str,
        message: str
    ) -> str:
        """Send a message to the artisan assigned to a booking."""
        nonlocal backend_client
        logger.info(f"📨 send_message_to_artisan called: booking_id={booking_id}, message={message!r}, backend_client={'SET' if backend_client else 'NONE'}")
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {'booking_id': booking_id, 'message': message}
            result = await backend_client.call_backend_action('send_message_to_artisan', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'no_artisan_assigned':
                    return "There's no artisan assigned to this booking yet. You can't send a message until an artisan accepts."
                elif error == 'booking_not_found':
                    return f"I couldn't find booking {booking_id}."
                return f"I couldn't send the message: {error}"

            return "Message sent to the artisan successfully. They'll be notified immediately."

        except Exception as e:
            logger.error(f"send_message_to_artisan error: {e}", exc_info=True)
            return "Sorry, I had trouble sending the message. Please try again."

    @llm.function_tool(
        description=(
            "Send a message to the client who booked. "
            "Use this when the artisan wants to contact their client (update on arrival, request info, etc.). "
            "Requires: booking_id, message."
        )
    )
    async def send_message_to_client(
        booking_id: str,
        message: str
    ) -> str:
        """Send a message to the client who made a booking."""
        nonlocal backend_client
        logger.info(f"📨 send_message_to_client called: booking_id={booking_id}, message={message!r}, backend_client={'SET' if backend_client else 'NONE'}")
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {'booking_id': booking_id, 'message': message}
            result = await backend_client.call_backend_action('send_message_to_client', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'no_client_on_booking':
                    return "There's no client associated with this booking."
                elif error == 'booking_not_found':
                    return f"I couldn't find booking {booking_id}."
                return f"I couldn't send the message: {error}"

            return "Message sent to the client successfully. They'll be notified immediately."

        except Exception as e:
            logger.error(f"send_message_to_client error: {e}", exc_info=True)
            return "Sorry, I had trouble sending the message. Please try again."

    @llm.function_tool(
        description=(
            "Send a message to admin support. "
            "Use this when the user needs help from support (complaints, escalations, complex issues). "
            "Requires: message. Optional: booking_id, subject."
        )
    )
    async def send_message_to_admin(
        message: str,
        booking_id: str = "",
        subject: str = "Support Request"
    ) -> str:
        """Send a message to admin support, creates a support case."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {
                'message': message,
                'subject': subject,
                'booking_id': booking_id or None
            }
            result = await backend_client.call_backend_action('send_message_to_admin', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"I couldn't send your message to support: {error}"

            case_id = (result.get('data') or result.get('result') or {}).get('case_id', '')
            if case_id:
                return f"I've forwarded your message to our support team (case {case_id}). They'll respond shortly and you'll be notified."
            else:
                return "I've forwarded your message to our support team. They'll respond shortly."

        except Exception as e:
            logger.error(f"send_message_to_admin error: {e}", exc_info=True)
            return "Sorry, I had trouble contacting support. Please try again."

    @llm.function_tool(
        description=(
            "Get chat messages for a booking. "
            "Use this when the user asks to see their messages or conversation with the artisan. "
            "Requires: booking_id or tasks_management_id."
        )
    )
    async def get_messages(
        booking_id: str = "",
        tasks_management_id: str = ""
    ) -> str:
        """Get chat messages for a booking."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        if not booking_id and not tasks_management_id:
            return "I need either a booking ID or tasks management ID to get messages."

        try:
            payload = {
                'booking_id': booking_id or None,
                'tasks_management_id': tasks_management_id or None,
                'limit': 10
            }
            result = await backend_client.call_backend_action('get_messages', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'booking_not_found':
                    return f"I couldn't find booking {booking_id}."
                elif error == 'no_tasks_management_id_for_booking':
                    return "This booking doesn't have a chat yet. You can send a message once an artisan is assigned."
                return f"I couldn't get the messages: {error}"

            result_data = result.get('data', result.get('result', {}))
            messages = result_data.get('messages', [])
            
            if not messages:
                return "There are no messages yet in this conversation."

            # Format messages for readability
            msg_list = []
            for msg in messages[-5:]:  # Last 5 messages
                sender = "You" if msg.get('sender_id') == backend_client.firebase_token else "Artisan"
                text = msg.get('message', '')
                msg_list.append(f"{sender}: {text}")

            messages_text = "\n".join(msg_list)
            return f"Recent messages:\n{messages_text}"

        except Exception as e:
            logger.error(f"get_messages error: {e}", exc_info=True)
            return "Sorry, I had trouble getting the messages. Please try again."

    # =========================================
    # Phase 3: Case Management Tools
    # =========================================

    @llm.function_tool(
        description=(
            "Get the status of a support case. "
            "Use this when the user asks about their support request or case. "
            "Requires: case_id."
        )
    )
    async def get_case_status(
        case_id: str
    ) -> str:
        """Get the status of a support case."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {'case_id': case_id}
            result = await backend_client.call_backend_action('get_case_status', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'case_not_found':
                    return f"I couldn't find case {case_id}."
                return f"I couldn't get the case status: {error}"

            result_data = result.get('data', result.get('result', {}))
            state = result_data.get('state', 'unknown')
            case_type = result_data.get('type', 'support')
            subject = result_data.get('subject', '')

            state_messages = {
                'open': "Your case is open and waiting for admin review.",
                'pending_admin': "Your case is waiting for admin action.",
                'in_progress': "Your case is being worked on by our team.",
                'resolved': "Your case has been resolved.",
                'closed': "Your case is closed."
            }

            status_msg = state_messages.get(state, f"Your case status is: {state}")
            if subject:
                return f"{subject} - {status_msg}"
            return status_msg

        except Exception as e:
            logger.error(f"get_case_status error: {e}", exc_info=True)
            return "Sorry, I had trouble getting the case status. Please try again."

    @llm.function_tool(
        description=(
            "Reply to an existing support case to add a follow-up message. "
            "Use when the user says 'reply to my case' or 'add a message to case XYZ'. "
            "Requires: case_id, message."
        )
    )
    async def reply_to_case(case_id: str, message: str) -> str:
        """Add a reply to an existing support case thread."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {'case_id': case_id, 'message': message}
            result = await backend_client.call_backend_action('reply_to_case', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"I couldn't add your reply: {error}"

            replies = (result.get('data') or {}).get('replies', 0)
            return f"Your reply has been added to case {case_id}. The support team will be notified. (Total messages: {replies})"
        except Exception as e:
            logger.error(f"reply_to_case error: {e}", exc_info=True)
            return "Sorry, I had trouble replying to your case. Please try again."

    @llm.function_tool(
        description=(
            "List the user's support cases. "
            "Use when user says 'show my cases', 'what are my open tickets?', 'do I have pending support requests?'. "
            "Optional: state filter ('open', 'in_progress', 'resolved', 'closed')."
        )
    )
    async def list_my_cases(state: str = "") -> str:
        """List user's support cases, optionally filtered by state."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {}
            if state:
                payload['state'] = state
            result = await backend_client.call_backend_action('list_my_cases', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"I couldn't fetch your cases: {error}"

            cases = (result.get('data') or {}).get('cases', [])
            if not cases:
                filter_msg = f' with status "{state}"' if state else ''
                return f"You don't have any support cases{filter_msg}."

            lines = [f"You have {len(cases)} case(s):"]
            for c in cases[:10]:
                cid = str(c.get('case_id', ''))[:8]
                subj = c.get('subject', c.get('type', 'General'))
                st = c.get('state', 'open')
                pri = c.get('priority', 'normal')
                replies = c.get('reply_count', 0)
                lines.append(f"• Case {cid}: {subj} — {st} (priority: {pri}, {replies} messages)")

            return "\n".join(lines)
        except Exception as e:
            logger.error(f"list_my_cases error: {e}", exc_info=True)
            return "Sorry, I had trouble fetching your cases. Please try again."

    # =========================================
    # Wallet & Booking Management Tools
    # =========================================

    @llm.function_tool(
        description=(
            "Get the user's wallet balance. "
            "Use this when the user asks 'What's my balance?' or 'How much is in my wallet?'"
        )
    )
    async def get_wallet_balance() -> str:
        """Get user's wallet balance from backend API."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            result = await backend_client.call_backend_action('get_wallet_balance', {})

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"I couldn't check your wallet balance: {error}"

            data = result.get('data', result.get('result', {}))
            balance = data.get('balance', '0')
            return f"Your wallet balance is R{balance}."

        except Exception as e:
            logger.error(f"get_wallet_balance error: {e}", exc_info=True)
            return "Sorry, I had trouble checking your wallet balance. Please try again."

    @llm.function_tool(
        description=(
            "Cancel a booking. Requires: booking_id and reason for cancellation. "
            "Use this when user asks to cancel a booking."
        )
    )
    async def cancel_booking(booking_id: str, reason: str = "") -> str:
        """Cancel a booking via backend API."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {'booking_id': booking_id, 'reason': reason or 'User requested cancellation'}
            result = await backend_client.call_backend_action('cancel_booking', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'booking_not_found':
                    return f"I couldn't find booking {booking_id}."
                return f"I couldn't cancel the booking: {error}"

            return f"Booking {booking_id} has been cancelled successfully."
        except Exception as e:
            logger.error(f"cancel_booking error: {e}", exc_info=True)
            return "Sorry, I had trouble cancelling the booking. Please try again."

    @llm.function_tool(
        description=(
            "Reschedule a booking to a new date and/or time. "
            "Requires: booking_id. Optional: scheduled_date, scheduled_time. "
            "Use this when user wants to change the time of their booking."
        )
    )
    async def reschedule_booking(booking_id: str, scheduled_date: str = "", scheduled_time: str = "") -> str:
        """Reschedule a booking via backend API."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        if not scheduled_date and not scheduled_time:
            return "I need at least a new date or time to reschedule. When would you like to reschedule to?"

        try:
            payload = {
                'booking_id': booking_id,
                'scheduled_date': scheduled_date or '',
                'scheduled_time': scheduled_time or '',
            }
            result = await backend_client.call_backend_action('reschedule_booking', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'booking_not_found':
                    return f"I couldn't find booking {booking_id}."
                return f"I couldn't reschedule: {error}"

            return f"Booking {booking_id} has been rescheduled to {scheduled_date} {scheduled_time}."
        except Exception as e:
            logger.error(f"reschedule_booking error: {e}", exc_info=True)
            return "Sorry, I had trouble rescheduling. Please try again."

    @llm.function_tool(
        description=(
            "Mark a booking as in-progress. Use this when artisan says they are starting work. "
            "Requires: booking_id."
        )
    )
    async def mark_booking_in_progress(booking_id: str) -> str:
        """Mark booking as in-progress via backend API."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {'booking_id': booking_id}
            result = await backend_client.call_backend_action('mark_booking_in_progress', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"I couldn't update the booking: {error}"

            return f"Booking {booking_id} is now marked as in-progress."
        except Exception as e:
            logger.error(f"mark_booking_in_progress error: {e}", exc_info=True)
            return "Sorry, I had trouble updating the booking status. Please try again."

    @llm.function_tool(
        description=(
            "Cancel current artisan assignment and request reassignment to a new artisan. "
            "Use this when artisan needs to hand off a job. Requires: booking_id, reason. "
            "IMPORTANT: You MUST verbally confirm with the artisan BEFORE calling this tool. "
            "Ask 'Are you sure you want to cancel and reassign?' and only call if they say yes."
        )
    )
    async def artisan_cancel_and_reassign(booking_id: str, reason: str = "") -> str:
        """Cancel artisan and reassign via backend API."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG

        try:
            payload = {'booking_id': booking_id, 'reason': reason or 'Artisan requested reassignment'}
            result = await backend_client.call_backend_action('artisan_cancel_and_reassign', payload)

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"I couldn't reassign: {error}"

            return f"Booking {booking_id} is being reassigned to a new artisan. If no one is available nearby, an admin will handle it."
        except Exception as e:
            logger.error(f"artisan_cancel_and_reassign error: {e}", exc_info=True)
            return "Sorry, I had trouble with the reassignment. Please try again."

    # ── New tools ─────────────────────────────────────────────────

    @llm.function_tool(
        description=(
            "Get the user's recent transaction history from their wallet. "
            "Shows deposits, payments, refunds and other wallet activity. "
            "Optional: limit (number of records, default 20)."
        )
    )
    async def get_transaction_history(limit: int = 20) -> str:
        """Fetch recent transaction logs for the user."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG
        try:
            result = await backend_client.call_backend_action('get_transaction_history', {'limit': limit})
            if not result.get('ok') and not result.get('success'):
                return f"Could not fetch transactions: {result.get('error', 'unknown')}"
            data = result.get('data', {})
            txns = data.get('transactions', [])
            if not txns:
                return "You have no recent transactions."
            lines = []
            for t in txns[:10]:  # Summarize top 10 for voice
                amt = t.get('amount', '0')
                typ = t.get('subtype') or t.get('type') or 'transaction'
                direction = t.get('direction', '')
                status = t.get('status', '')
                date = (t.get('transaction_at') or '')[:10]
                arrow = "received" if direction == 'in' else "spent"
                lines.append(f"R{amt} {typ.replace('_', ' ')} ({arrow}) on {date} — {status}")
            summary = "; ".join(lines)
            return f"Here are your recent transactions: {summary}"
        except Exception as e:
            logger.error(f"get_transaction_history error: {e}", exc_info=True)
            return "Sorry, I couldn't fetch your transaction history right now."

    @llm.function_tool(
        description=(
            "Get the user's deposit/top-up requests. Shows pending, approved and rejected deposit requests."
        )
    )
    async def get_deposit_requests(limit: int = 10) -> str:
        """Fetch deposit requests for the user."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG
        try:
            result = await backend_client.call_backend_action('get_deposit_requests', {'limit': limit})
            if not result.get('ok') and not result.get('success'):
                return f"Could not fetch deposits: {result.get('error', 'unknown')}"
            data = result.get('data', {})
            deposits = data.get('deposits', [])
            if not deposits:
                return "You have no deposit requests."
            lines = []
            for d in deposits:
                amt = d.get('amount', '0')
                status = d.get('status', 'pending')
                date = (d.get('created_at') or '')[:10]
                lines.append(f"R{amt} — {status} ({date})")
            return f"Your deposit requests: {'; '.join(lines)}"
        except Exception as e:
            logger.error(f"get_deposit_requests error: {e}", exc_info=True)
            return "Sorry, I couldn't fetch your deposit requests right now."

    @llm.function_tool(
        description=(
            "Get available service categories. Lists all services that can be booked through the app."
        )
    )
    async def get_service_categories() -> str:
        """Fetch available service categories."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG
        try:
            result = await backend_client.call_backend_action('get_service_categories', {})
            if not result.get('ok') and not result.get('success'):
                return f"Could not fetch categories: {result.get('error', 'unknown')}"
            data = result.get('data', {})
            cats = data.get('categories', [])
            if not cats:
                return "No service categories found."
            names = [c.get('name', 'Unknown') for c in cats]
            return f"Available service categories: {', '.join(names)}"
        except Exception as e:
            logger.error(f"get_service_categories error: {e}", exc_info=True)
            return "Sorry, I couldn't fetch service categories right now."

    @llm.function_tool(
        description=(
            "Get the user's recent notifications. Shows alerts about bookings, payments and updates."
        )
    )
    async def get_notifications(limit: int = 10) -> str:
        """Fetch recent notifications for the user."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG
        try:
            result = await backend_client.call_backend_action('get_notifications', {'limit': limit})
            if not result.get('ok') and not result.get('success'):
                return "Could not fetch notifications."
            data = result.get('data', {})
            notifs = data.get('notifications', [])
            if not notifs:
                return "You have no recent notifications."
            lines = []
            for n in notifs[:5]:  # Top 5 for voice
                title = n.get('title', 'Notification')
                msg = n.get('message', '')
                lines.append(f"{title}: {msg}" if msg else title)
            return f"Your recent notifications: {'; '.join(lines)}"
        except Exception as e:
            logger.error(f"get_notifications error: {e}", exc_info=True)
            return "Sorry, I couldn't fetch your notifications right now."

    @llm.function_tool(
        description=(
            "Get the user's upcoming/scheduled bookings. Shows future bookings that haven't been completed or cancelled."
        )
    )
    async def get_scheduled_bookings() -> str:
        """Fetch upcoming scheduled bookings."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG
        try:
            result = await backend_client.call_backend_action('get_scheduled_bookings', {})
            if not result.get('ok') and not result.get('success'):
                return f"Could not fetch bookings: {result.get('error', 'unknown')}"
            data = result.get('data', {})
            bookings = data.get('bookings', [])
            if not bookings:
                return "You have no upcoming scheduled bookings."
            lines = []
            for b in bookings:
                name = b.get('task_name') or 'Service'
                date = b.get('scheduled_date') or 'TBD'
                time = b.get('scheduled_time') or ''
                status = b.get('status') or ''
                lines.append(f"{name} on {date} {time} ({status})")
            return f"Your upcoming bookings: {'; '.join(lines)}"
        except Exception as e:
            logger.error(f"get_scheduled_bookings error: {e}", exc_info=True)
            return "Sorry, I couldn't fetch your scheduled bookings right now."

    @llm.function_tool(
        description=(
            "Get information about an artisan/service provider. "
            "Requires: artisan_id (the service provider's ID)."
        )
    )
    async def get_artisan_info(artisan_id: str) -> str:
        """Fetch details about a specific artisan."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG
        try:
            result = await backend_client.call_backend_action('get_artisan_info', {'artisan_id': artisan_id})
            if not result.get('ok') and not result.get('success'):
                return f"Could not find artisan: {result.get('error', 'unknown')}"
            data = result.get('data', {})
            name = data.get('name', 'Unknown')
            rating = data.get('rating')
            location = data.get('location', '')
            rating_text = f", rated {rating}/5" if rating else ""
            location_text = f", based in {location}" if location else ""
            return f"Artisan {name}{rating_text}{location_text}"
        except Exception as e:
            logger.error(f"get_artisan_info error: {e}", exc_info=True)
            return "Sorry, I couldn't fetch artisan information right now."

    @llm.function_tool(
        description=(
            "Submit a rating for a completed booking. "
            "Requires: booking_id, rating (1-5). Optional: review (text comment)."
        )
    )
    async def submit_rating(booking_id: str, rating: int, review: str = "") -> str:
        """Rate an artisan after service completion."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG
        try:
            payload = {'booking_id': booking_id, 'rating': rating, 'review': review}
            result = await backend_client.call_backend_action('submit_rating', payload)
            if not result.get('ok') and not result.get('success'):
                return f"Could not submit rating: {result.get('error', 'unknown')}"
            return f"Thank you! Your {rating}-star rating has been submitted for booking {booking_id}."
        except Exception as e:
            logger.error(f"submit_rating error: {e}", exc_info=True)
            return "Sorry, I couldn't submit your rating right now."

    @llm.function_tool(
        description=(
            "Submit a complaint about a service or experience. "
            "Requires: description (what went wrong). Optional: subject, booking_id."
        )
    )
    async def submit_complaint(description: str, subject: str = "Complaint", booking_id: str = "") -> str:
        """File a complaint with the admin team."""
        nonlocal backend_client
        if not backend_client:
            if not await _ensure_backend_or_retry():
                return _CONNECTION_RETRY_MSG
        try:
            payload = {'description': description, 'subject': subject, 'booking_id': booking_id}
            result = await backend_client.call_backend_action('submit_complaint', payload)
            if not result.get('ok') and not result.get('success'):
                return f"Could not submit complaint: {result.get('error', 'unknown')}"
            complaint_id = result.get('data', {}).get('complaint_id', '')
            return f"Your complaint has been submitted (ref: {complaint_id}). Our team will review it shortly."
        except Exception as e:
            logger.error(f"submit_complaint error: {e}", exc_info=True)
            return "Sorry, I couldn't submit your complaint right now."

    # =========================================
    # Screen Awareness Tools (OpenClaw-like)
    # =========================================

    # Live screen context from the app (updated via metadata on every navigation)
    _current_screen_context: Dict[str, Any] = {}

    @llm.function_tool(
        description=(
            "Get information about what screen the user is currently viewing in the app. "
            "Returns the screen name, description, available actions, and any visible data. "
            "Use this when user asks 'What am I looking at?', 'What's on my screen?', "
            "'Where am I in the app?', 'What can I do here?', or when you need to understand "
            "the current context before taking an action."
        )
    )
    async def get_current_screen() -> str:
        """Get the current screen context from the app."""
        nonlocal _current_screen_context

        if not _current_screen_context:
            # Try to get context from app by requesting a context update
            await _set_agent_metadata({
                "type": "square15_ui",
                "action": "request_context",
                "payload": {},
                "text": "",
            })
            await asyncio.sleep(1)  # Brief wait for app to respond

        if not _current_screen_context:
            return "You are currently in the Square 15 app. I can navigate to any screen for you. Just tell me where you'd like to go or what you'd like to do."

        screen_name = _current_screen_context.get('screen_name', 'App Screen')
        screen_desc = _current_screen_context.get('screen_description', '')
        actions = _current_screen_context.get('available_actions', [])
        screen_data = _current_screen_context.get('screen_data', {})
        route = _current_screen_context.get('current_route', '')

        response = f"You are on the {screen_name} screen."
        if screen_desc:
            response += f" {screen_desc}"
        if screen_data:
            for key, val in screen_data.items():
                readable_key = key.replace('_', ' ')
                response += f" {readable_key}: {val}."
        if actions:
            action_names = [a.replace('_', ' ') for a in actions[:8]]  # Top 8 for voice
            response += f" Available actions: {', '.join(action_names)}."

        return response

    @llm.function_tool(
        description=(
            "Analyze and interpret what's displayed on the user's current screen. "
            "Provides a detailed summary of the visible information and suggests "
            "what actions the user might want to take. "
            "Use this when user says 'Analyze this page', 'What does this mean?', "
            "'Explain what I'm seeing', 'Help me understand this screen'."
        )
    )
    async def analyze_screen() -> str:
        """Analyze the current screen and provide intelligent insights."""
        nonlocal _current_screen_context, app_context_bookings

        screen = _current_screen_context.get('screen_name', 'App Screen')
        screen_data = _current_screen_context.get('screen_data', {})
        route = _current_screen_context.get('current_route', '')

        # Build analysis based on screen type and available data
        parts = [f"Analyzing the {screen} screen for you."]

        r = (route or '').lower()
        if 'wallet' in r:
            balance = screen_data.get('wallet_balance', '')
            if balance:
                parts.append(f"Your current wallet balance is {balance} rand.")
            parts.append("From here you can view transaction history, check deposit requests, or go back to the home screen.")
            parts.append("Would you like me to show your transaction history or check if you have any pending deposits?")

        elif 'dashboard' in r or r == '/':
            name = screen_data.get('user_name', '')
            count = screen_data.get('active_bookings_count', 0)
            if name:
                parts.append(f"Welcome {name}.")
            if count and int(str(count)) > 0:
                parts.append(f"You have {count} active booking{'s' if int(str(count)) > 1 else ''}.")
                parts.append("Would you like me to show your bookings, check their status, or create a new one?")
            else:
                parts.append("You have no active bookings right now.")
                parts.append("Would you like to create a new booking, check your wallet, or look at service pricing?")

        elif 'booking' in r or 'future' in r:
            if app_context_bookings:
                parts.append(f"I can see {len(app_context_bookings)} booking{'s' if len(app_context_bookings) > 1 else ''}.")
                for b in app_context_bookings[:3]:
                    cat = b.get('category', 'service')
                    status = b.get('status', 'unknown')
                    parts.append(f"• {cat}: {status}")
                parts.append("Would you like to check a specific booking, reschedule, cancel, or contact the artisan?")
            else:
                parts.append("I can help you manage your bookings from here. Would you like to check a booking status or create a new one?")

        elif 'notification' in r:
            parts.append("This shows your notifications about bookings, payments, and system updates.")
            parts.append("Would you like me to read your recent notifications?")

        elif 'profile' in r:
            parts.append("This is your profile page where you can view and update your personal information.")

        elif 'support' in r or 'chat' in r:
            parts.append("This is the support chat where you can contact the admin team.")
            parts.append("Would you like me to send a message to support?")

        elif 'calendar' in r:
            parts.append("This is your calendar showing scheduled services and upcoming appointments.")

        else:
            parts.append("I can see you're in the app. Tell me what you'd like to do and I'll help you.")

        return " ".join(parts)

    @llm.function_tool(
        description=(
            "Get a complete list of all screens and features available in the Square 15 app. "
            "Use this when user asks 'What can you do?', 'What features are available?', "
            "'Show me everything', 'What screens are there?'"
        )
    )
    async def list_app_features() -> str:
        """List all available screens and features in the app."""
        return (
            "Here are all the screens and features available in the Square 15 app:\n\n"
            "NAVIGATION:\n"
            "• Home Dashboard — main screen with service categories and quick actions\n"
            "• Future Bookings — view all your upcoming bookings\n"
            "• Wallet — check balance, deposits, and transaction history\n"
            "• Notifications — booking updates, payment alerts, system messages\n"
            "• Profile — your personal information\n"
            "• Settings — app preferences and account management\n"
            "• Support Chat — contact admin team\n"
            "• Calendar — scheduled services and appointments\n\n"
            "BOOKING ACTIONS:\n"
            "• Create a new booking with any service category\n"
            "• Cancel a booking\n"
            "• Reschedule a booking to a new date/time\n"
            "• Check booking status and details\n"
            "• Call the assigned artisan\n"
            "• Send a message to an artisan\n"
            "• View RFQ quote details\n"
            "• Submit a rating after service\n\n"
            "WALLET & PAYMENTS:\n"
            "• Check wallet balance\n"
            "• View transaction history\n"
            "• Check deposit request status\n\n"
            "COMMUNICATION:\n"
            "• Send messages to artisans\n"
            "• Contact admin support\n"
            "• Submit complaints\n"
            "• View chat messages\n\n"
            "INFORMATION:\n"
            "• Look up service pricing\n"
            "• View service categories\n"
            "• Check artisan information\n"
            "• View notifications\n\n"
            "Just tell me what you'd like to do and I'll help you."
        )

    agent = voice.Agent(
        vad=vad,
        stt=openai.STT(model="whisper-1", language="en"),
        llm=openai.LLM(model="gpt-4o-mini", temperature=0.4),
        tts=openai.TTS(model="tts-1", voice="alloy"),
        instructions=_instructions_for_role(caller_role),
    )

    logger.info("🚀 Starting agent session...")
    session = voice.AgentSession(
        tools=[
            ui_navigate,
            # Read-only backend tools
            get_booking_status,
            list_my_bookings,
            get_booking_analytics,
            explain_quote,
            check_payment,
            get_wallet_balance,
            lookup_service_pricing,
            get_transaction_history,
            get_deposit_requests,
            get_service_categories,
            get_notifications,
            get_scheduled_bookings,
            get_artisan_info,
            # Write backend tools
            create_booking,
            cancel_booking,
            reschedule_booking,
            mark_booking_in_progress,
            artisan_cancel_and_reassign,
            submit_rating,
            submit_complaint,
            # Phase 3: Messaging tools
            send_message_to_artisan,
            send_message_to_client,
            send_message_to_admin,
            get_messages,
            # Phase 3: Case management
            get_case_status,
            reply_to_case,
            list_my_cases,
            # Screen awareness tools (OpenClaw-like)
            get_current_screen,
            analyze_screen,
            list_app_features,
        ],
        # --- Latency optimizations ---
        min_endpointing_delay=0.25,       # default 0.5 — faster turn completion
        max_endpointing_delay=1.5,        # default 3.0 — don't wait too long
        preemptive_generation=True,        # start LLM+TTS before turn confirmed
        min_interruption_duration=0.4,     # default 0.5 — faster interruption
    )

    # Guardrail: never allow internal/tool narration to reach TTS.
    _orig_say = session.say

    def _say_sanitized(text: str, *args, **kwargs):
        cleaned = _sanitize_spoken_text(text)
        if not cleaned:
            return None
        return _orig_say(cleaned, *args, **kwargs)

    session.say = _say_sanitized

    # ── CRITICAL: Register event handlers BEFORE session.start() ──
    # The app sends credentials via publishData immediately after connecting.
    # If we register handlers after session.start(), we miss the data packet.
    last_metadata_by_identity: dict[str, str] = {}

    def _try_init_backend_from_msg(msg: dict):
        """Shared helper to initialize backend_client from a credentials message."""
        nonlocal backend_client, firebase_token, session_id, session_nonce
        ft = msg.get("firebase_token")
        if not ft:
            logger.debug("_try_init_backend_from_msg: no firebase_token in msg")
            return False
        logger.info(f"🔑 _try_init_backend_from_msg: got token (len={len(ft)}, starts={ft[:20]}...)")
        firebase_token = ft
        session_id = msg.get("session_id")
        session_nonce = msg.get("session_nonce")
        backend_client = BackendAPIClient(
            base_url=backend_url,
            firebase_token=firebase_token,
            session_id=session_id,
            session_nonce=session_nonce
        )
        return True

    def on_participant_metadata_changed(participant, old_metadata, new_metadata):
        nonlocal backend_client, firebase_token, session_id, session_nonce, app_context_bookings, app_context_user_id
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

            msg_type = (msg.get("type") or "").strip()

            # Handle voice session credentials from app
            if msg_type == "square15_voice_credentials":
                if _try_init_backend_from_msg(msg):
                    logger.info(f"✅ Backend client initialized with credentials (session: {session_id[:12] if session_id else 'none'}...)")
                return

            # ALWAYS extract firebase_token from ANY metadata if backend_client not yet set.
            # The access-token metadata and context messages both embed the token,
            # so we must check every incoming metadata update.
            if not backend_client:
                ft = msg.get('firebase_token')
                if ft:
                    sid = msg.get('voice_session_id') or msg.get('session_id')
                    snonce = msg.get('voice_session_nonce') or msg.get('session_nonce')
                    if _try_init_backend_from_msg({
                        'firebase_token': ft,
                        'session_id': sid,
                        'session_nonce': snonce,
                    }):
                        logger.info("✅ Backend client initialized from embedded metadata token")

            if msg_type != "square15_app":
                return

            action = (msg.get("action") or "").strip()
            payload = msg.get("payload") if isinstance(msg.get("payload"), dict) else {}

            if action == "speak":
                text = _sanitize_spoken_text(
                    (payload.get("text") or msg.get("text") or "")
                )
                if not text:
                    return
                session.say(text, allow_interruptions=True)
            elif action == "context":
                # Store app context data (active bookings, user_id) for tool fallback
                bookings = payload.get("active_bookings")
                if isinstance(bookings, list) and bookings:
                    app_context_bookings = bookings
                    logger.info(f"📋 Received {len(bookings)} active bookings from app context")
                uid = (payload.get("user_id") or "").strip()
                if uid:
                    app_context_user_id = uid
                # Store screen context for OpenClaw-like screen awareness
                screen_ctx = payload.get("screen_context")
                if isinstance(screen_ctx, dict):
                    _current_screen_context.clear()
                    _current_screen_context.update(screen_ctx)
                    logger.info(f"📱 Screen context updated: {screen_ctx.get('screen_name', 'unknown')}")
        except Exception as e:
            logger.info(f"metadata handler error (ignored): {e}")

    def on_data_received(data_packet):
        """Handle data channel messages — used for credentials delivery."""
        nonlocal backend_client, firebase_token, session_id, session_nonce
        try:
            raw = None
            if hasattr(data_packet, 'data'):
                raw = data_packet.data
            elif isinstance(data_packet, bytes):
                raw = data_packet
            if raw is None:
                logger.debug("📦 data_received: no data attribute")
                return
            text = raw.decode('utf-8') if isinstance(raw, (bytes, bytearray)) else str(raw)
            if not text or not text.strip():
                return
            logger.info(f"📦 data_received: len={len(text)}, preview={text[:100]}...")
            msg = json.loads(text)
            if not isinstance(msg, dict):
                return
            msg_type = (msg.get('type') or '').strip()
            if msg_type == 'square15_voice_credentials':
                if _try_init_backend_from_msg(msg):
                    logger.info(f"✅ Backend client initialized via DATA CHANNEL (session: {session_id[:12] if session_id else 'none'}...)")
        except Exception as e:
            logger.debug(f"data_received handler note: {e}")

    try:
        ctx.room.on("participant_metadata_changed", on_participant_metadata_changed)
        ctx.room.on("data_received", on_data_received)
        logger.info("✅ Listening for app metadata + data channel (square15_app)")
    except Exception as e:
        logger.warning(f"⚠️ Could not attach metadata listener: {e}")

    # ── Scan existing participants for credentials that arrived before we joined ──
    # The backend embeds firebase_token in the participant's access token metadata,
    # so we can read it directly from any remote participant's metadata JSON.
    def _scan_participants_for_credentials():
        """Scan all remote participants for firebase_token in metadata."""
        nonlocal backend_client, app_context_bookings, app_context_user_id
        try:
            participants = ctx.room.remote_participants
            # Handle both dict.values() and direct iteration
            items = participants.values() if hasattr(participants, 'values') else participants
            participant_count = 0
            for p in items:
                participant_count += 1
                if backend_client:
                    break  # Already initialized
                ident = getattr(p, 'identity', '???')
                md = getattr(p, 'metadata', None)
                if not md or not str(md).strip():
                    logger.debug(f"🔍 Participant {ident}: no metadata")
                    continue
                logger.info(f"🔍 Participant {ident}: metadata len={len(md)}, preview={md[:120]}...")
                try:
                    msg = json.loads(md)
                    if not isinstance(msg, dict):
                        continue
                    # Check for firebase_token — either from access token metadata (backend-embedded)
                    # or from square15_voice_credentials (app-sent)
                    ft = msg.get('firebase_token')
                    if ft and not backend_client:
                        sid = msg.get('voice_session_id') or msg.get('session_id')
                        snonce = msg.get('voice_session_nonce') or msg.get('session_nonce')
                        if _try_init_backend_from_msg({
                            'firebase_token': ft,
                            'session_id': sid,
                            'session_nonce': snonce,
                        }):
                            logger.info("✅ Backend client initialized from participant metadata")
                    # Also extract app context data
                    bookings = msg.get('active_bookings')
                    if isinstance(bookings, list) and bookings:
                        app_context_bookings = bookings
                    uid = (msg.get('user_id') or '').strip()
                    if uid:
                        app_context_user_id = uid
                except Exception:
                    pass
            logger.info(f"🔍 Scan complete: {participant_count} participants scanned, backend_client={'SET' if backend_client else 'NONE'}, app_bookings={len(app_context_bookings)}")
        except Exception as e:
            logger.warning(f"⚠️ Participant scan error: {e}")

    _scan_participants_for_credentials()

    await session.start(agent, room=ctx.room)
    logger.info("✅ Agent session started and running!")

    # ── Post-start: re-scan in case metadata arrived during start ──
    if not backend_client:
        await asyncio.sleep(0.5)  # Brief wait for late-arriving metadata
        _scan_participants_for_credentials()
        if backend_client:
            logger.info("✅ Backend client initialized from post-start scan")

    try:
        session.say(
            "Hi, I am Lizzy, how can I help you today?",
            allow_interruptions=True,
        )
        logger.info("✅ Greeting sent")
    except Exception as e:
        logger.warning(f"⚠️ Could not send greeting: {e}")

    # ── Background: periodically retry credential scan until backend_client is set ──
    async def _credential_retry_loop():
        for i in range(40):  # Try for ~60 seconds
            if backend_client:
                logger.info(f"✅ Backend client confirmed initialized (retry loop check {i+1})")
                return
            await asyncio.sleep(1.5)
            _scan_participants_for_credentials()
            if backend_client:
                logger.info(f"✅ Backend client initialized from retry loop (attempt {i+1})")
                return
            if i % 5 == 4:
                logger.info(f"⏳ Credential retry loop: {i+1}/40 attempts, still no backend_client")
        if not backend_client:
            logger.warning("⚠️ Backend client never initialized after 60s — booking tools will use app context fallback only")

    asyncio.ensure_future(_credential_retry_loop())

    while ctx.room.connection_state != rtc.ConnectionState.CONN_DISCONNECTED:
        await asyncio.sleep(1)


async def request_handler(ctx: JobContext):
    try:
        await entrypoint(ctx)
    except Exception as e:
        logger.error(f"❌ Fatal error in request handler: {e}", exc_info=True)


if __name__ == "__main__":
    logger.info("=" * 60)
    logger.info(f"🚀 Square 15 Voice Agent Worker  v{WORKER_VERSION}")
    logger.info("=" * 60)
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
