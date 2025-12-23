const express = require('express');
const path = require('path');
const { AgentDispatchClient } = require('livekit-server-sdk');

// Load env vars from repo root (.env sits two levels up from this file)
// and also from the current working directory.
try {
  // eslint-disable-next-line global-require
  require('dotenv').config({ path: path.resolve(__dirname, '..', '..', '.env') });
  // eslint-disable-next-line global-require
  require('dotenv').config();
} catch {
  // dotenv is optional; process.env may already be configured.
}

const app = express();
app.use(express.json());

// LiveKit configuration
const LIVEKIT_URL = process.env.LIVEKIT_URL;
const LIVEKIT_API_KEY = process.env.LIVEKIT_API_KEY;
const LIVEKIT_API_SECRET = process.env.LIVEKIT_API_SECRET;
const LIVEKIT_AGENT_NAME = process.env.LIVEKIT_AGENT_NAME || 'square15-voice-assistant';

if (!LIVEKIT_URL || !LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) {
  // Fail fast with a clear message.
  // eslint-disable-next-line no-console
  console.error(
    '❌ Missing LiveKit config. Set LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET (optionally LIVEKIT_AGENT_NAME).'
  );
  process.exit(1);
}

const agentDispatchClient = new AgentDispatchClient(
  LIVEKIT_URL.replace('wss://', 'https://'),
  LIVEKIT_API_KEY,
  LIVEKIT_API_SECRET
);

// Dispatch agent endpoint
app.post('/api/dispatch-agent', async (req, res) => {
  const { roomName, metadata } = req.body;
  
  console.log(`📞 Dispatch request received for room: ${roomName}`);
  
  try {
    if (!roomName || typeof roomName !== 'string') {
      return res.status(400).json({
        success: false,
        error: 'roomName is required',
      });
    }

    // Explicit dispatch: requires your worker to be started with a matching agent_name.
    const dispatchInfo = await agentDispatchClient.createDispatch(roomName, LIVEKIT_AGENT_NAME, {
      metadata: typeof metadata === 'string' ? metadata : undefined,
    });

    console.log(`✅ Agent dispatch created for room: ${roomName}`);
    res.status(200).json({
      success: true,
      message: 'Agent dispatch created',
      roomName,
      agentName: LIVEKIT_AGENT_NAME,
      dispatch: dispatchInfo || null,
    });
  } catch (error) {
    console.error(`❌ Error dispatching agent:`, error.message);
    res.status(500).json({ 
      success: false, 
      error: error.message 
    });
  }
});

// Health check endpoint
app.get('/health', (req, res) => {
  res.json({
    status: 'ok',
    message: 'Dispatch server running',
    agentName: LIVEKIT_AGENT_NAME,
  });
});

const PORT = 3001;  // Changed from 3000 to avoid conflict with main backend
app.listen(PORT, '0.0.0.0', () => {
  console.log(`🚀 LiveKit Agent Dispatch Server running on port ${PORT}`);
  console.log(`📡 Listening on all interfaces (0.0.0.0:${PORT})`);
  console.log(`🔗 Local: http://localhost:${PORT}`);
  console.log(`🔗 Network: http://192.168.123.36:${PORT}`);
  console.log(`\n⚠️  Main backend should run on port 3000`);
  console.log(`⚠️  This dispatch server uses port 3001`);
  console.log(`\nReady to receive dispatch requests...`);
});
