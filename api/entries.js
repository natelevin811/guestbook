const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
  try {
    const supabase = createClient(
      process.env.SUPABASE_URL,
      process.env.SUPABASE_ANON_KEY
    );

    if (req.method === 'GET') {
      const { data, error } = await supabase
        .from('entries')
        .select('*')
        .order('created_at', { ascending: false });

      if (error) return res.status(500).json({ error: error.message });
      return res.json(data);
    }

    if (req.method === 'POST') {
      const body = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
      const { name, message } = body || {};

      if (!name || !String(name).trim() || !message || !String(message).trim()) {
        return res.status(400).json({ error: 'Name and message are required.' });
      }

      const { data, error } = await supabase
        .from('entries')
        .insert({ name: String(name).trim(), message: String(message).trim() })
        .select()
        .single();

      if (error) return res.status(500).json({ error: error.message });
      return res.status(201).json(data);
    }

    res.status(405).json({ error: 'Method not allowed' });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
};
