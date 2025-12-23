// Generate a LiveKit access token for a room
// Reads LIVEKIT_API_KEY, LIVEKIT_API_SECRET, ROOM_NAME, AGENT_IDENTITY from env
// Usage: node gen_lk_token.js

const { AccessToken } = require('livekit-server-sdk');

const apiKey = process.env.LIVEKIT_API_KEY;
const apiSecret = process.env.LIVEKIT_API_SECRET;
const roomName = process.env.ROOM_NAME || 'square15-voice-assistant';
const identity = process.env.AGENT_IDENTITY || 'square15-agent';

if (!apiKey || !apiSecret) {
  console.error('[!] LIVEKIT_API_KEY or LIVEKIT_API_SECRET not set');
  process.exit(1);
}

async function main() {
  try {
    const at = new AccessToken(apiKey, apiSecret, {
      identity,
      name: identity,
    });

    at.addGrant({
      roomJoin: true,
      room: roomName,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
    });

    const jwt = await at.toJwt();
    process.stdout.write(jwt);
  } catch (e) {
    console.error('[!] Failed to generate token:', e?.message || e);
    process.exit(1);
  }
}

main();
