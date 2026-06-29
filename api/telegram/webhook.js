// POST /api/telegram/webhook  — Telegram updates (the opt-out / mute path).
//
// Set the webhook once with:
//   curl "https://api.telegram.org/bot<TOKEN>/setWebhook?url=<PUBLIC_BASE_URL>/api/telegram/webhook&secret_token=<TELEGRAM_WEBHOOK_SECRET>"
//
// Supported commands (in the group chat):
//   /stop   -> mute the weekly digest
//   /start  -> unmute
//   /windows-> reply with the current free-for-all windows
//   /ping   -> health check

const { getSupabase } = require('../../lib/supabase');
const { sendMessage } = require('../../lib/telegram');
const { computeWindows } = require('../../lib/digest');
const { buildDigestMessage } = require('../../lib/format');
const config = require('../../lib/config');

async function setMute(chatId, muted) {
  const supabase = getSupabase();
  await supabase.from('mutes').upsert(
    { chat_id: String(chatId), muted, updated_at: new Date().toISOString() },
    { onConflict: 'chat_id' }
  );
}

module.exports = async (req, res) => {
  // Verify Telegram's secret header if configured.
  const expected = process.env.TELEGRAM_WEBHOOK_SECRET;
  if (expected && req.headers['x-telegram-bot-api-secret-token'] !== expected) {
    res.status(401).json({ ok: false });
    return;
  }

  try {
    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : req.body || {};
    const msg = body.message || body.channel_post;
    const text = (msg?.text || '').trim().toLowerCase();
    const chatId = msg?.chat?.id;

    if (!chatId || !text) {
      res.status(200).json({ ok: true });
      return;
    }

    const cmd = text.split(/\s+/)[0].replace(/@.*$/, ''); // strip @botname

    if (cmd === '/stop' || cmd === 'stop') {
      await setMute(chatId, true);
      await sendMessage(chatId, 'muted. you won’t get the weekly free-window digest. reply /start to turn it back on.');
    } else if (cmd === '/start' || cmd === 'start' || cmd === '/unmute') {
      await setMute(chatId, false);
      await sendMessage(chatId, 'back on — i’ll ping you when you’re all free.');
    } else if (cmd === '/windows') {
      const { windows } = await computeWindows();
      const message = buildDigestMessage(windows, config.GROUP_TIMEZONE)
        || 'no windows where everyone’s free right now.';
      await sendMessage(chatId, message);
    } else if (cmd === '/ping') {
      await sendMessage(chatId, 'pong');
    }

    res.status(200).json({ ok: true });
  } catch (err) {
    // Always 200 so Telegram doesn't hammer retries; log for debugging.
    console.error('telegram webhook error:', err.message);
    res.status(200).json({ ok: true });
  }
};
