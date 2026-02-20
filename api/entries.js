const { createClient } = require('@supabase/supabase-js');

module.exports = async (req, res) => {
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
    const { name, message } = req.body;

    if (!name || !name.trim() || !message || !message.trim()) {
      return res.status(400).json({ error: 'Name and message are required.' });
    }

    const { data, error } = await supabase
      .from('entries')
      .insert({ name: name.trim(), message: message.trim() })
      .select()
      .single();

    if (error) return res.status(500).json({ error: error.message });
    return res.status(201).json(data);
  }

  res.status(405).json({ error: 'Method not allowed' });
};
