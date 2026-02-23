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
import aiohttp
from typing import Optional, Dict, Any


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
    logger.info(f"🎯 New job received for room: {room_name}")

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
            "- When user asks to DO something, CALL the right tool immediately.\n"
            "- BACKEND tools for data: get_booking_status, list_my_bookings, explain_quote, check_payment, get_wallet_balance, get_messages, get_case_status.\n"
            "- lookup_service_pricing for pricing: when user asks 'how much is...', 'what's the price for...', 'how much do you charge for...', call lookup_service_pricing with category_name or task_name.\n"
            "- ui_navigate for screens: open_bookings_tab, open_wallet, open_profile, open_settings, open_notifications, open_calendar, open_help, open_support, go_home, go_back, close_window.\n"
            "- send_message_to_artisan, send_message_to_admin for messaging.\n"
            "- NEVER narrate tool calls. Never say JSON, function names, or metadata.\n"
            "- NEVER claim you opened/loaded pictures or images.\n"
            "- NEVER claim you opened a map or showed a location. There is no map feature.\n"
            "- Speak naturally, 1-3 short sentences. Be concise.\n"
            "- If user says 'now'/'asap'/'urgent', use scheduled_date='now', scheduled_time='now'.\n"
            "- Date format: YYYY-MM-DD. Time format: HH:MM.\n"
            "- If user refers to a booking by price, call list_my_bookings first to find it.\n"
            "\n"
            "PRICING ENQUIRIES (IMPORTANT):\n"
            "- When user asks how much a service costs, ALWAYS call lookup_service_pricing first.\n"
            "- Provide category_name (e.g. 'plumbing') and/or task_name (e.g. 'unblock toilet').\n"
            "- Read back the price from the results. If cost is null, say 'This service requires a quote from an artisan'.\n"
            "- NEVER guess or make up prices. Always use lookup_service_pricing to get actual prices.\n"
            "- If lookup_service_pricing is not available or fails, tell the user: 'I'm having trouble retrieving our pricing right now. Please check the services section in the app or try again shortly.'\n"
            "\n"
            "BOOKING CREATION (IMPORTANT):\n"
            "- To create a new booking, ALWAYS use ui_navigate with action='create_order_booking'.\n"
            "- Provide: category_name, problem_description, and optionally scheduled_date, scheduled_time, service_address.\n"
            "- Do NOT use create_booking tool. ONLY use ui_navigate(action='create_order_booking').\n"
            "- After calling ui_navigate, say 'I am processing your booking now, please keep the app open.' Do NOT say an artisan has been sent or dispatched until the app confirms it.\n"
            "- NEVER open photo upload, map, or any other screen during booking creation. The app handles everything automatically.\n"
            "- Do NOT use open_map or show_location actions. They do not exist.\n"
        )

        if role == "artisan":
            base += (
                "\nARTISAN ACTIONS:\n"
                "- Accept job → ui_navigate(action='accept_latest_request')\n"
                "- Reject job → ui_navigate(action='reject_latest_request')\n"
                "- Start job → mark_booking_in_progress(booking_id)\n"
                "- Cancel+reassign → artisan_cancel_and_reassign(booking_id, reason)\n"
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
            "Supported actions: create_order_booking, dispatch_artisan, "
            "open_bookings_tab, open_future_bookings, open_artisan_requests, open_artisan_appointments, "
            "open_artisan_wallet, accept_latest_request, reject_latest_request, respond_to_request, "
            "call_assigned_artisan, reschedule_booking, cancel_booking, reassign_booking, "
            "mark_booking_in_progress, artisan_cancel_and_reassign, "
            "open_notifications, open_profile, open_settings, open_support, open_wallet, "
            "open_calendar, open_help, go_home, go_back, close_window, close_dialog, dismiss."
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
        nonlocal backend_client
        if not backend_client:
            return "I need you to be authenticated first. Please make sure you're logged into the app."

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

            data = result.get('data', {})
            status = data.get('status', 'unknown')
            category = data.get('category_name', 'service')
            scheduled_date = data.get('scheduled_date', '')
            scheduled_time = data.get('scheduled_time', '')
            artisan_confirmed = data.get('artisan_confirmed', '')

            response = f"Booking {booking_id} for {category}: Status is {status}."
            if scheduled_date and scheduled_time:
                response += f" Scheduled for {scheduled_date} at {scheduled_time}."
            if artisan_confirmed:
                response += f" Artisan confirmation: {artisan_confirmed}."

            artisan = data.get('artisan')
            if artisan and isinstance(artisan, dict):
                name = artisan.get('name', '')
                phone = artisan.get('phone', '')
                if name:
                    response += f" Artisan: {name}."
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
        nonlocal backend_client
        if not backend_client:
            return "I need you to be authenticated first. Please make sure you're logged into the app."

        try:
            result = await backend_client.list_user_bookings(status=status or None, limit=min(limit, 10))
            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"There was an issue getting your bookings: {error}"

            data = result.get('data', {})
            bookings = data.get('bookings', [])
            count = len(bookings)

            if count == 0:
                return "You don't have any bookings" + (f" with status {status}" if status else "") + "."

            response = f"You have {count} booking" + ("s" if count > 1 else "") + ".\n"
            for i, booking in enumerate(bookings[:10], 1):
                booking_id = booking.get('booking_id', 'unknown')
                booking_status = booking.get('status', 'unknown')
                category = booking.get('category_name', 'service')
                date = booking.get('scheduled_date', '')
                time = booking.get('scheduled_time', '')
                price = booking.get('total_price', '')
                rfq_no = booking.get('rfq_no', '')
                order_no = booking.get('order_number', '')
                order_type = booking.get('order_type', '')
                rfq_status = booking.get('rfq_status', '')
                response += f"{i}. {category} booking {booking_id}: {booking_status}"
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
            return "I need you to be authenticated first. Please make sure you're logged into the app."

        try:
            result = await backend_client.call_backend_action("get_booking_analytics", {})
            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"There was an issue getting analytics: {error}"

            data = result.get('data', {})
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
            return "I need you to be authenticated first. Please make sure you're logged into the app."

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

            data = result.get('data', {})
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
            return "I need you to be authenticated first. Please make sure you're logged into the app."

        try:
            result = await backend_client.get_payment_status(booking_id)
            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"There was an issue checking payment: {error}"

            data = result.get('data', {})
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
            return response
        except Exception as e:
            logger.error(f"lookup_service_pricing error: {e}", exc_info=True)
            # Last resort: return hardcoded pricing so Lizzy can ALWAYS answer
            return (
                "I'm having a temporary connection issue, but here are our current prices from my records:\n\n"
                "Bathroom:\n"
                "  - Install a bath tub: R1890.00\n"
                "  - Install basin: R1220.00\n"
                "  - Install toilet and cistern: R1575.00\n"
                "  - Unblock a blocked toilet: R1575.00\n\n"
                "Kitchen:\n"
                "  - Install kitchen mixer tap (L): R950.00\n\n"
                "Painting:\n"
                "  - Ceiling: R44.00 per sqm\n"
                "  - Enamel painting of Ceiling and walls: R105.00 per sqm\n"
                "  - Garage Door: R750.00\n"
                "  - PVA Wall Paint and ceiling: R95.00 per sqm\n"
                "  - Roof: R200.00 per sqm\n"
                "  - Varnish door frame Labour only: R480.00\n"
                "  - Wall: R100.00 per sqm\n\n"
                "Tiling:\n"
                "  - Tiling Task: R15.00 per sqm\n\n"
                "Note: These prices may not reflect the very latest updates. Please check the app for the most current pricing."
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
            return "I need you to be authenticated first. Please make sure you're logged into the app."

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
        if not backend_client:
            return "I need you to be authenticated first."

        try:
            payload = {'booking_id': booking_id, 'message': message}
            result = await backend_client.call_backend_action('send_message_to_artisan', payload)

            if not result.get('success'):
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
            return "I need you to be authenticated first."

        try:
            payload = {
                'message': message,
                'subject': subject,
                'booking_id': booking_id or None
            }
            result = await backend_client.call_backend_action('send_message_to_admin', payload)

            if not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"I couldn't send your message to support: {error}"

            case_id = (result.get('result') or {}).get('case_id', '')
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
            return "I need you to be authenticated first."

        if not booking_id and not tasks_management_id:
            return "I need either a booking ID or tasks management ID to get messages."

        try:
            payload = {
                'booking_id': booking_id or None,
                'tasks_management_id': tasks_management_id or None,
                'limit': 10
            }
            result = await backend_client.call_backend_action('get_messages', payload)

            if not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'booking_not_found':
                    return f"I couldn't find booking {booking_id}."
                elif error == 'no_tasks_management_id_for_booking':
                    return "This booking doesn't have a chat yet. You can send a message once an artisan is assigned."
                return f"I couldn't get the messages: {error}"

            result_data = result.get('result', {})
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
            return "I need you to be authenticated first."

        try:
            payload = {'case_id': case_id}
            result = await backend_client.call_backend_action('get_case_status', payload)

            if not result.get('success'):
                error = result.get('error', 'unknown_error')
                if error == 'case_not_found':
                    return f"I couldn't find case {case_id}."
                return f"I couldn't get the case status: {error}"

            result_data = result.get('result', {})
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
            return "I need you to be authenticated first. Please make sure you're logged into the app."

        try:
            result = await backend_client.call_backend_action('get_wallet_balance', {})

            if not result.get('ok') and not result.get('success'):
                error = result.get('error', 'unknown_error')
                return f"I couldn't check your wallet balance: {error}"

            data = result.get('data', {})
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
            return "I need you to be authenticated first."

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
            return "I need you to be authenticated first."

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
            return "I need you to be authenticated first."

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
            "Use this when artisan needs to hand off a job. Requires: booking_id, reason."
        )
    )
    async def artisan_cancel_and_reassign(booking_id: str, reason: str = "") -> str:
        """Cancel artisan and reassign via backend API."""
        nonlocal backend_client
        if not backend_client:
            return "I need you to be authenticated first."

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
            # Write backend tools
            create_booking,
            cancel_booking,
            reschedule_booking,
            mark_booking_in_progress,
            artisan_cancel_and_reassign,
            # Phase 3: Messaging tools
            send_message_to_artisan,
            send_message_to_admin,
            get_messages,
            # Phase 3: Case management
            get_case_status,
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
    await session.start(agent, room=ctx.room)
    logger.info("✅ Agent session started and running!")

    # Listen for app -> agent metadata messages (e.g. booking updates).
    # The Flutter app will set its own participant metadata to JSON:
    #   {"type":"square15_app","action":"speak","payload":{"text":"..."},...}
    last_metadata_by_identity: dict[str, str] = {}

    def on_participant_metadata_changed(participant, old_metadata, new_metadata):
        nonlocal backend_client, firebase_token, session_id, session_nonce
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
                firebase_token = msg.get("firebase_token")
                session_id = msg.get("session_id")
                session_nonce = msg.get("session_nonce")
                if firebase_token:
                    backend_client = BackendAPIClient(
                        base_url=backend_url,
                        firebase_token=firebase_token,
                        session_id=session_id,
                        session_nonce=session_nonce
                    )
                    logger.info(f"✅ Backend client initialized with credentials (session: {session_id[:12] if session_id else 'none'}...)")
                return

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
                return
            text = raw.decode('utf-8') if isinstance(raw, (bytes, bytearray)) else str(raw)
            if not text or not text.strip():
                return
            msg = json.loads(text)
            if not isinstance(msg, dict):
                return
            msg_type = (msg.get('type') or '').strip()
            if msg_type == 'square15_voice_credentials':
                firebase_token = msg.get('firebase_token')
                session_id = msg.get('session_id')
                session_nonce = msg.get('session_nonce')
                if firebase_token:
                    backend_client = BackendAPIClient(
                        base_url=backend_url,
                        firebase_token=firebase_token,
                        session_id=session_id,
                        session_nonce=session_nonce
                    )
                    logger.info(f"✅ Backend client initialized via DATA CHANNEL (session: {session_id[:12] if session_id else 'none'}...)")
        except Exception as e:
            logger.debug(f"data_received handler note: {e}")

    try:
        ctx.room.on("participant_metadata_changed", on_participant_metadata_changed)
        ctx.room.on("data_received", on_data_received)
        logger.info("✅ Listening for app metadata + data channel (square15_app)")
    except Exception as e:
        logger.warning(f"⚠️ Could not attach metadata listener: {e}")

    try:
        session.say(
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
