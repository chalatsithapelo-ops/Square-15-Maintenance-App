# Square 15 - Livekit Backend Server

Backend server for generating secure Livekit access tokens for the Square 15 voice AI assistant.

## 🚀 Quick Start

### 1. Install Dependencies

```bash
cd livekit-backend
npm install
```

### 2. Configure Environment

Edit the `.env` file and add your Livekit credentials:

```env
LIVEKIT_API_KEY=APIfA2HcvgKpuuV
LIVEKIT_API_SECRET=your-actual-secret-here
LIVEKIT_WS_URL=wss://square-15-maintenance-app-n6ijx3po.livekit.cloud
LIVEKIT_AGENT_NAME=square15-voice-assistant
```

**To get your API Secret:**
1. Go to https://cloud.livekit.io/projects
2. Select your project: "square-15-maintenance-app-n6ijx3po"
3. Go to Settings → API Keys
4. Copy your API Secret

### 3. Start Server

**Development mode (with auto-reload):**
```bash
npm run dev
```

**Production mode:**
```bash
npm start
```

The server will start on `http://localhost:3000`

## 📡 API Endpoints

### Health Check
```http
GET /health
```

**Response:**
```json
{
  "status": "ok",
  "message": "Livekit Token Server is running",
  "timestamp": "2025-12-20T10:30:00.000Z"
}
```

### Generate Access Token
```http
POST /api/token
Content-Type: application/json

{
  "roomName": "voice-assistant-12345",
  "participantName": "user_john_doe",
  "metadata": "{\"userId\": \"user123\"}"
}
```

**Response:**
```json
{
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "url": "wss://square-15-maintenance-app-n6ijx3po.livekit.cloud",
  "roomName": "voice-assistant-12345",
  "participantName": "user_john_doe"
}
```

### Create Room
```http
POST /api/create-room
Content-Type: application/json

{
  "roomName": "custom-room-name" // optional
}
```

### Start Voice Session (Recommended)
This single endpoint does everything the mobile app needs **without depending on your laptop LAN IP**:

1) Creates/chooses a room name
2) Generates a LiveKit token (server-side, API secret never goes into the app)
3) Dispatches the AI agent into the room

```http
POST /api/voice/start
Content-Type: application/json

{
  "participantName": "user_john_doe", // optional
  "roomName": "square15-voice-123",   // optional
  "metadata": "{\"userId\":\"user123\"}" // optional
}
```

**Response:**
```json
{
  "roomName": "square15-voice-123",
  "participantName": "user_john_doe",
  "token": "...",
  "url": "wss://square-15-maintenance-app-n6ijx3po.livekit.cloud",
  "agentName": "square15-voice-assistant"
}
```

### Dispatch Agent
```http
POST /api/dispatch-agent
Content-Type: application/json

{
  "roomName": "square15-voice-123"
}
```

### Secure Action API (Firestore writes via backend)
```http
POST /api/action/execute
Authorization: Bearer <Firebase ID token>
Idempotency-Key: <string>   # optional but recommended
Content-Type: application/json

{
  "action": "create_order_booking",
  "payload": { "problem_description": "..." },
  "context": { "source": "voice" }
}
```

**Async mode (queued + poll):**
- Send header `Prefer: respond-async` (or query `?async=1`)
- Poll `GET /api/action/job/:id` with the same Firebase ID token

**Admin endpoints (admin role required):**
- `GET /api/admin/audit/:id`
- `GET /api/admin/jobs/:id`
- `POST /api/admin/jobs/process-next?limit=1`

## 🔒 Security Notes

1. **Never commit your `.env` file** - Add it to `.gitignore`
2. **Use HTTPS in production** - Deploy behind a reverse proxy
3. **Validate requests** - Add authentication middleware
4. **Rate limiting** - Implement rate limiting for production
5. **CORS configuration** - Update `ALLOWED_ORIGINS` for production

### Optional security tuning env vars
- `RATE_LIMIT_PER_MINUTE` (default `120` for `/api/*`)
- `JSON_BODY_LIMIT` (default `200kb`)

## 🌐 Deployment Options

## ✅ Recommended: Render (Works Everywhere)

This is the simplest option if you are not technical.

You will deploy **two things** so the app works anywhere (mobile data, no laptop):
- A **public HTTPS backend** (creates tokens + dispatches the agent)
- A **cloud AI worker** (the agent that joins rooms and speaks)

### Step-by-step (Render)
1) Put this project on GitHub (if you haven’t already).
2) Create a free Render account.
3) In Render, choose: **New +** → **Blueprint**.
4) Select your GitHub repo and deploy.
  - Render will automatically read the blueprint file: [render.yaml](render.yaml)
5) After it deploys, open the service **square15-livekit-backend** and set these Environment Variables:
  - `LIVEKIT_WS_URL` = `wss://square-15-maintenance-app-n6ijx3po.livekit.cloud`
  - `LIVEKIT_API_KEY` = (your key)
  - `LIVEKIT_API_SECRET` = (your secret)
  - `LIVEKIT_AGENT_NAME` = `square15-voice-assistant`
6) Open the service **square15-agent-worker** and set these Environment Variables:
  - `LIVEKIT_URL` = `wss://square-15-maintenance-app-n6ijx3po.livekit.cloud`
  - `LIVEKIT_API_KEY` = (your key)
  - `LIVEKIT_API_SECRET` = (your secret)
  - `LIVEKIT_AGENT_NAME` = `square15-voice-assistant`
  - `OPENAI_API_KEY` = (your OpenAI key)
7) Copy the public backend URL from Render. It looks like:
  - `https://square15-livekit-backend.onrender.com`

### Final step: make the mobile app use the cloud backend
Build the Flutter app with your backend URL:

```bash
flutter build apk --dart-define=LIVEKIT_BACKEND_URL=https://YOUR_BACKEND_DOMAIN
```

Then install that APK on your phone.

Once this is done, the app will work **anywhere** because it no longer depends on `192.168.x.x` or your laptop.

### Option 1: Heroku
```bash
heroku create square15-livekit-backend
heroku config:set LIVEKIT_API_KEY=your-key
heroku config:set LIVEKIT_API_SECRET=your-secret
git push heroku main
```

### Option 2: Railway
1. Connect your GitHub repository
2. Add environment variables in Railway dashboard
3. Deploy automatically

### Option 3: DigitalOcean App Platform
1. Create new app from GitHub
2. Configure environment variables
3. Deploy

### Option 4: VPS (Linux Server)
```bash
# Install Node.js
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs

# Clone and setup
git clone your-repo
cd livekit-backend
npm install

# Use PM2 for process management
npm install -g pm2
pm2 start server.js --name "livekit-backend"
pm2 startup
pm2 save
```

## 🧪 Testing

Test the server with curl:

```bash
# Health check
curl http://localhost:3000/health

# Generate token
curl -X POST http://localhost:3000/api/token \
  -H "Content-Type: application/json" \
  -d '{
    "roomName": "test-room",
    "participantName": "test-user"
  }'
```

## 📝 Environment Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `LIVEKIT_API_KEY` | Your Livekit API Key | ✅ |
| `LIVEKIT_API_SECRET` | Your Livekit API Secret | ✅ |
| `LIVEKIT_WS_URL` | Livekit WebSocket URL | ✅ |
| `LIVEKIT_AGENT_NAME` | Explicit agent dispatch name (must match worker) | ✅ |
| `PORT` | Server port (default: 3000) | ❌ |
| `NODE_ENV` | Environment (development/production) | ❌ |
| `ALLOWED_ORIGINS` | CORS allowed origins | ❌ |

## 🐛 Troubleshooting

**Problem:** Server won't start
- Check if port 3000 is already in use
- Verify all dependencies are installed
- Check `.env` file exists and is configured

**Problem:** Token generation fails
- Verify your Livekit API credentials are correct
- Check Livekit dashboard for project status
- Ensure WebSocket URL is correct

**Problem:** CORS errors
- Update `ALLOWED_ORIGINS` in `.env`
- Check Flutter app is making requests to correct URL

## 📞 Support

For issues, contact the development team or check:
- Livekit Documentation: https://docs.livekit.io
- Livekit Dashboard: https://cloud.livekit.io
