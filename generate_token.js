// LiveKit token generator
// Usage: node generate_token.js <roomName> <identity>
// Requires env LIVEKIT_API_KEY and LIVEKIT_API_SECRET

const { AccessToken } = require('livekit-server-sdk');

function main() {
  const room = process.argv[2] || process.env.ROOM_NAME || 'square15-voice-assistant';
  const identity = process.argv[3] || process.env.AGENT_IDENTITY || 'square15-agent';
  const apiKey = process.env.LIVEKIT_API_KEY;
  const apiSecret = process.env.LIVEKIT_API_SECRET;

  if (!apiKey || !apiSecret) {
    console.error('[!] LIVEKIT_API_KEY or LIVEKIT_API_SECRET not set');
    process.exit(1);
  }

  const at = new AccessToken(apiKey, apiSecret, { identity });
  at.addGrant({
    roomJoin: true,
    room,
    canPublish: true,
    canSubscribe: true,
  });

  (async () => {
    const token = await at.toJwt();
    console.log(token);
  })().catch((err) => {
    console.error('[!] Failed to generate token:', err);
    process.exit(1);
  });
}

main();
