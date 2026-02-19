const express = require('express');
const path = require('path');
const { createClient } = require('@supabase/supabase-js');

const app = express();
const PORT = 3000;

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_ANON_KEY
);

app.use(express.urlencoded({ extended: true }));
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Expose public Supabase config to the browser
app.get('/config', (req, res) => {
  res.json({
    supabaseUrl: process.env.SUPABASE_URL,
    supabaseAnonKey: process.env.SUPABASE_ANON_KEY,
  });
});

// Get all entries
app.get('/entries', async (req, res) => {
  const { data, error } = await supabase
    .from('entries')
    .select('*')
    .order('created_at', { ascending: false });

  if (error) return res.status(500).json({ error: error.message });
  res.json(data);
});

// Submit a new entry
app.post('/entries', async (req, res) => {
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
  res.status(201).json(data);
});

app.listen(PORT, () => {
  console.log(`Guestbook running at http://localhost:${PORT}`);
});
