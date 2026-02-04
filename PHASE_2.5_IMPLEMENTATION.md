# Phase 2.5 Implementation Complete
## Agent-Worker Backend Integration

**Date**: 2025-01-26  
**Status**: ✅ IMPLEMENTED  
**Commits**: Phase 2.5 agent-worker integration

---

## Overview

Phase 2.5 connects the LiveKit voice agent worker to the backend API, enabling true voice-driven AI actions. This is the **critical integration** that makes the voice AI functional for Square 15's "selling point" feature.

### What Changed

**Before Phase 2.5:**
- Agent only set participant metadata (UI remote control)
- Flutter app made all backend API calls
- Agent couldn't truly "execute actions" - just told app what to do
- All Phase 0/1/2 backend security bypassed

**After Phase 2.5:**
- Agent directly calls backend APIs with proper authentication
- Agent uses Firebase Auth tokens and session binding
- Agent leverages all Phase 0/1/2 backend features
- True voice AI: "What's my booking status?" → agent calls API → speaks result

---

## Implementation Details

### 1. Backend API Client (`BackendAPIClient`)

**Location**: `agent-worker/voice_agent_worker.py` lines ~38-195

**Purpose**: HTTP client for calling Square 15 backend action endpoints

**Features**:
- Firebase ID token authentication (`Authorization: Bearer <token>`)
- Session binding (session_id + session_nonce for Phase 0 security)
- Async HTTP with aiohttp (30s timeout)
- Support for Phase 2 read-only tools
- Support for Phase 1 propose/confirm workflow

**Methods**:
```python
async def get_booking_status(booking_id: str) -> Dict[str, Any]
async def list_user_bookings(status: Optional[str], limit: int) -> Dict[str, Any]
async def explain_rfq_quote(booking_id: str) -> Dict[str, Any]
async def get_payment_status(booking_id: str) -> Dict[str, Any]
async def propose_action(action: str, payload: Dict[str, Any]) -> Dict[str, Any]
async def confirm_action(proposal_id: str) -> Dict[str, Any]
```

### 2. Function Tools for Phase 2 (Read-Only)

**Location**: `agent-worker/voice_agent_worker.py` lines ~450-600

#### `get_booking_status(booking_id: str)`
- Calls `/api/action/execute` with action='get_booking_status'
- Returns booking status, artisan details, scheduled time
- Speaks result naturally: "Booking 123 for Plumbing: Status is in_progress. Scheduled for 2025-01-27 at 14:00. Artisan: John Smith."

#### `list_my_bookings(status: str = "", limit: int = 5)`
- Calls `/api/action/execute` with action='list_user_bookings'
- Returns up to 10 bookings (default 5)
- Speaks result: "You have 3 bookings. 1. Plumbing booking 123: in_progress on 2025-01-27 at 14:00..."

#### `explain_quote(booking_id: str)`
- Calls `/api/action/execute` with action='explain_rfq_quote'
- Returns RFQ quote details and explanation
- Speaks result: "Quote status: approved. Quoted price: R500. Details: Materials included, 2-hour job."

#### `check_payment(booking_id: str)`
- Calls `/api/action/execute` with action='get_payment_status'
- Returns payment status and transaction history
- Speaks result: "Payment status: paid. Latest transaction: R500, status: completed."

### 3. Function Tools for Phase 1 (Write with Propose/Confirm)

**Location**: `agent-worker/voice_agent_worker.py` lines ~600-680

#### `create_booking(...)`
- Implements full propose→confirm workflow
- First calls `/api/action/propose` with action='create_order_booking'
- Then calls `/api/action/confirm` with proposalId
- Respects Tier C blocking (if enabled)
- Speaks result: "Booking 456 created successfully! Dispatching the nearest available artisan now."

**Parameters**:
- `category_name` (required): Trade category (Plumbing, Electrical, etc.)
- `problem_description` (required): Issue description
- `scheduled_date` (optional): yyyy-MM-dd format
- `scheduled_time` (optional): HH:mm:ss format
- `service_address` (optional): Service location
- `is_rfq` (optional): "yes" for RFQ requests

### 4. Credential Flow

**Flutter App → Agent**:
1. App calls `/api/voice/start` to get session_id + session_nonce
2. App joins LiveKit room with Firebase ID token
3. App sends participant metadata:
   ```json
   {
     "type": "square15_voice_credentials",
     "firebase_token": "<Firebase ID token>",
     "session_id": "<from /api/voice/start>",
     "session_nonce": "<from /api/voice/start>"
   }
   ```
4. Agent receives metadata and initializes BackendAPIClient

**Agent → Backend**:
1. Agent constructs request with:
   - `Authorization: Bearer <firebase_token>`
   - `Content-Type: application/json`
   - Body includes `context: {session_id, session_nonce}`
2. Backend validates Firebase token (Phase 0)
3. Backend validates session binding if enabled (Phase 0)
4. Backend executes action respecting tier policy (Phase 1)
5. Backend returns result
6. Agent speaks result naturally

### 5. Updated Agent Instructions

**Location**: `agent-worker/voice_agent_worker.py` lines ~300-370

**Key Changes**:
- Agent now knows about TWO tool types: BACKEND (API calls) and UI (navigation)
- For queries (status/info), use BACKEND tools
- For UI navigation (opening screens), use ui_navigate
- For writes (create/cancel), use create_booking with auto-propose/confirm
- Never narrate tool calls - just speak results
- Authenticate before backend calls - if auth fails, guide user to log in

**Example Instructions**:
```
INFORMATION QUERIES - Use backend tools:
- 'What's my booking status?' → CALL get_booking_status(booking_id='...')
- 'Show my bookings' → CALL list_my_bookings(status='', limit=5)
- 'Explain my quote' → CALL explain_quote(booking_id='...')
- 'Did I pay?' → CALL check_payment(booking_id='...')
Then SPEAK the result naturally.

CREATE BOOKING - Use backend tool:
- Identify category from symptoms
- Collect: category_name + problem_description
- CALL create_booking(category_name='...', problem_description='...', ...)
- This handles proposal→confirmation automatically
```

---

## Security Integration

### Phase 0 Security (All Active)

✅ **Firebase Authentication**
- Agent passes Firebase ID token in Authorization header
- Backend validates token via Firebase Admin SDK
- Only authenticated users can call backend

✅ **Session Binding**
- Agent passes session_id + session_nonce in context
- Backend validates session is valid and not expired
- Backend validates nonce matches session
- Prevents token hijacking

✅ **Audit Trail**
- All agent actions logged to `assistant_action_audit` collection
- Includes: uid, action, payload, context, timestamp, success/failure

### Phase 1 Security (Tier Policy)

✅ **Propose/Confirm Workflow**
- Write operations use propose→confirm
- Agent calls propose first, gets proposalId
- Agent calls confirm with proposalId
- Server re-validates proposal before execution

✅ **Tier C Blocking**
- If backend has `TIER_C_BLOCKED=true`
- Agent's create_booking will fail at propose stage
- Agent speaks error: "I couldn't create the booking proposal: tier_c_blocked"

---

## Testing

### Test Script

**Location**: `test_agent_backend_integration.py`

**Run**: `python test_agent_backend_integration.py`

**Tests**:
1. ✅ Backend client initialization
2. ✅ Authorization header construction (Bearer token)
3. ✅ Session context construction (session_id + session_nonce)
4. ✅ API method signatures (all 6 methods async)
5. ✅ Payload construction for Phase 2 tools
6. ✅ Propose/Confirm workflow structure

**Results**: All tests passing ✅

### End-to-End Testing

**Requirements**:
1. Valid Firebase ID token from authenticated user
2. Active LiveKit room with agent worker
3. Flutter app sending credentials metadata

**Test Scenarios**:

**Scenario 1: Query booking status**
```
User: "What's the status of booking 123?"
Agent: CALL get_booking_status('123')
Agent: "Your plumbing booking is in progress. John the plumber is on the way. Contact: 0721234567."
```

**Scenario 2: List bookings**
```
User: "Show my bookings"
Agent: CALL list_my_bookings(status='', limit=5)
Agent: "You have 2 bookings. 1. Plumbing booking 123: in_progress on 2025-01-27 at 14:00. 2. Electrical booking 456: pending_assignment on 2025-01-28 at 10:00."
```

**Scenario 3: Create booking**
```
User: "Dispatch a plumber, my tap is leaking"
Agent: CALL create_booking(category_name='Plumbing', problem_description='Leaking tap', ...)
Agent: "Booking 789 created successfully! Dispatching the nearest available artisan now. You'll be notified once an artisan accepts."
```

**Scenario 4: Auth failure**
```
User: "What's my booking status?" (not logged in)
Agent: CALL get_booking_status('123') → backend returns 401
Agent: "I need you to be authenticated first. Please make sure you're logged into the app."
```

---

## Deployment

### Prerequisites

1. ✅ Backend deployed with Phase 0/1/2 (done - Render)
2. ✅ Agent-worker has aiohttp dependency (done - requirements.txt)
3. ✅ Environment variable: `BACKEND_API_URL=https://square15-livekit-backend.onrender.com`
4. ⏳ Flutter app updated to send credentials metadata (pending)

### Agent-Worker Deployment

**Option 1: Render**
1. Push changes to GitHub
2. Render auto-deploys from main branch
3. Verify `BACKEND_API_URL` env var set

**Option 2: Local Testing**
```bash
cd agent-worker
pip install -r ../requirements.txt
export OPENAI_API_KEY=sk-...
export LIVEKIT_URL=wss://...
export LIVEKIT_API_KEY=...
export LIVEKIT_API_SECRET=...
export BACKEND_API_URL=https://square15-livekit-backend.onrender.com
python voice_agent_worker.py dev
```

### Flutter App Changes Required

**Location**: Flutter client voice session code

**Add credentials metadata sender**:
```dart
// After joining LiveKit room and getting session credentials
final metadata = jsonEncode({
  'type': 'square15_voice_credentials',
  'firebase_token': await FirebaseAuth.instance.currentUser!.getIdToken(),
  'session_id': voiceStartResponse['session_id'],
  'session_nonce': voiceStartResponse['session_nonce'],
});

await localParticipant.updateMetadata(metadata);
```

**When to send**: Immediately after joining room, before agent starts listening

---

## Success Criteria

### ✅ Completed

- [x] Backend API client class implemented
- [x] Firebase Auth integration (token passing)
- [x] Session binding (session_id + session_nonce)
- [x] Phase 2 read-only tools (4 endpoints)
- [x] Phase 1 write tools with propose/confirm
- [x] Agent instructions updated
- [x] Test script created and passing
- [x] Documentation complete

### ⏳ Pending (Flutter App)

- [ ] Flutter app sends credentials metadata
- [ ] End-to-end testing with real Firebase token
- [ ] Production deployment verification

---

## Troubleshooting

### Issue: "I need you to be authenticated first"

**Cause**: Agent doesn't have Firebase token

**Fix**: Ensure Flutter app sends credentials metadata:
```json
{
  "type": "square15_voice_credentials",
  "firebase_token": "<valid_token>",
  "session_id": "<session_id>",
  "session_nonce": "<session_nonce>"
}
```

### Issue: Backend returns 401 Unauthorized

**Cause**: Invalid or expired Firebase token

**Fix**: Flutter app should refresh token before sending:
```dart
await FirebaseAuth.instance.currentUser!.getIdToken(forceRefresh: true)
```

### Issue: Backend returns 403 Forbidden (session_binding_failed)

**Cause**: Invalid session_nonce or expired session

**Fix**: 
1. Check `/api/voice/start` response includes session_nonce
2. Check session_nonce matches what was stored
3. Check session hasn't expired (default 1 hour)

### Issue: "tier_c_blocked" error

**Cause**: Backend has `TIER_C_BLOCKED=true` for safety

**Fix**: 
1. If in production, this is expected (Tier C disabled)
2. Use Flutter app UI for write operations
3. Agent can guide user: "I can't create bookings right now. Please use the app to dispatch an artisan."

---

## Next Steps

### Phase 3: Expand Backend Tools

**Potential additions**:
- Cancel booking tool (propose/confirm)
- Reschedule booking tool (propose/confirm)
- Reassign artisan tool (propose/confirm)
- Get artisan location/ETA
- Send message to artisan

**Implementation pattern**: Same as create_booking
1. Add backend handler in server.js
2. Register in ACTION_HANDLERS + ACTION_TIERS
3. Add function tool in voice_agent_worker.py
4. Use propose/confirm for writes
5. Speak results naturally

### Phase 4: Advanced Features

**Future enhancements**:
- Multi-turn conversations (booking creation wizard)
- Proactive notifications ("Your artisan is 5 minutes away")
- Voice payment confirmation
- Voice RFQ quote approval
- Integration with calendar/scheduling

---

## Files Changed

### Modified Files

1. **agent-worker/voice_agent_worker.py**
   - Added BackendAPIClient class (lines ~38-195)
   - Added backend function tools (lines ~450-680)
   - Updated agent instructions (lines ~300-370)
   - Added credential metadata listener (lines ~760-790)
   - Updated session tool list (line ~690)

### New Files

1. **test_agent_backend_integration.py**
   - Comprehensive test suite for Phase 2.5
   - Tests client initialization, auth, session binding
   - Validates all API methods and payloads

### Configuration Files

1. **requirements.txt** (already had aiohttp)
   - No changes needed - dependencies already correct

---

## Commit Messages

```
Phase 2.5: Connect agent-worker to backend APIs

- Add BackendAPIClient with Firebase Auth + session binding
- Implement Phase 2 read-only function tools (4 endpoints)
  * get_booking_status
  * list_my_bookings  
  * explain_quote
  * check_payment
- Implement Phase 1 write tool with propose/confirm
  * create_booking (auto-propose/confirm)
- Update agent instructions for backend vs UI tools
- Add credentials metadata listener
- Create comprehensive test suite
- Document Phase 2.5 implementation

This enables true voice AI: agent calls backend directly,
respects all Phase 0/1/2 security controls, and speaks
results naturally. Critical "selling point" feature.
```

---

## Summary

Phase 2.5 successfully bridges the gap between the LiveKit voice agent and the Square 15 backend API. The agent can now:

1. ✅ Authenticate with Firebase tokens
2. ✅ Respect session binding security
3. ✅ Query booking/payment/quote information
4. ✅ Create bookings with propose/confirm
5. ✅ Speak results naturally to users
6. ✅ Leverage all Phase 0/1/2 backend features

This transforms the agent from a "UI remote control" to a true voice AI assistant - the **non-negotiable selling point** of the Square 15 app.

**Status**: ✅ Implementation complete, ready for Flutter app integration and end-to-end testing.
