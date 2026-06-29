// GET /api/members — who's connected (names only, never tokens).
// Powers the "3 of your crew are connected" status on the connect page.

const { getSupabase } = require('../lib/supabase');

module.exports = async (req, res) => {
  try {
    const supabase = getSupabase();
    const { data, error } = await supabase
      .from('app_users')
      .select('name, created_at')
      .order('created_at', { ascending: true });
    if (error) {
      res.status(500).json({ error: error.message });
      return;
    }
    res.status(200).json({
      count: (data || []).length,
      members: (data || []).map((m) => ({ name: m.name })),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
};
