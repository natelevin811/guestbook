// GET /api/cron/digest  — the scheduled job (Vercel Cron, weekly).
// Auth: Vercel Cron sends `Authorization: Bearer ${CRON_SECRET}` when
// CRON_SECRET is configured. Manual runs may pass ?secret=... instead.

const { runDigest } = require('../../lib/digest');

function authorized(req) {
  const secret = process.env.CRON_SECRET;
  if (!secret) return true; // no secret configured -> open (dev only)
  const header = req.headers?.authorization;
  if (header === `Bearer ${secret}`) return true;
  if ((req.query?.secret || '') === secret) return true;
  return false;
}

module.exports = async (req, res) => {
  if (!authorized(req)) {
    res.status(401).json({ error: 'unauthorized' });
    return;
  }
  try {
    const dryRun = req.query?.dry === '1';
    const result = await runDigest({ send: !dryRun, record: !dryRun });
    res.status(200).json(result);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
};
