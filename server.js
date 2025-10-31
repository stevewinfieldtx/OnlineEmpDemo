const express = require('express');
const path = require('path');
const dotenv = require('dotenv');
const axios = require('axios');
const { Pool } = require('pg');
const auth = require('basic-auth');
const { v4: uuidv4 } = require('uuid');

// Load environment variables
dotenv.config();

const app = express();
const PORT = process.env.PORT || 3001;

// Database connection
// Ensure your DATABASE_URL includes SSL config if required by your host
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// Middleware
app.use(express.static(path.join(__dirname, 'public'))); // Serve static files
app.use(express.json()); // Parse JSON bodies
app.use(express.urlencoded({ extended: true })); // Parse form data
app.set('view engine', 'ejs'); // Set EJS as the templating engine

// --- Authentication Middleware for Admin ---
const checkAuth = (req, res, next) => {
  const credentials = auth(req);
  if (!credentials || 
      credentials.name !== process.env.ADMIN_USERNAME || 
      credentials.pass !== process.env.ADMIN_PASSWORD) {
    res.setHeader('WWW-Authenticate', 'Basic realm="Admin Access"');
    return res.status(401).send('Access denied');
  }
  next();
};

// --- Public Prospect-Facing Route ---
app.get('/', async (req, res) => {
  const prospectId = req.query.prospect;
  if (!prospectId) {
    // Optional: Render a generic "Welcome to WinTech" page if no ID
    return res.status(404).send('Prospect not found. Please use a valid demo link.');
  }

  try {
    const result = await pool.query('SELECT * FROM prospects WHERE unique_id = $1', [prospectId]);
    if (result.rows.length === 0) {
      return res.status(404).send('Prospect not found.');
    }
    const prospect = result.rows[0];
    res.render('demo', {
      prospectName: prospect.name,
      prospectId: prospect.unique_id
    });
  } catch (err) {
    console.error('Database query error:', err);
    res.status(500).send('Server error');
  }
});

// --- Admin Routes ---
app.get('/admin', checkAuth, async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM prospects ORDER BY id DESC');
    // Get the base URL to display links correctly
    const baseUrl = `${req.protocol}://${req.get('host')}`;
    res.render('admin_dashboard', { prospects: result.rows, baseUrl: baseUrl });
  } catch (err) {
    console.error('Admin dashboard error:', err);
    res.status(500).send('Server error');
  }
});

app.post('/admin/create', checkAuth, async (req, res) => {
  const { prospectName, systemPrompt } = req.body;
  const uniqueId = uuidv4(); // Generate a unique ID

  try {
    await pool.query(
      'INSERT INTO prospects (name, system_prompt, unique_id) VALUES ($1, $2, $3)',
      [prospectName, systemPrompt, uniqueId]
    );
    res.redirect('/admin');
  } catch (err) {
    console.error('Error creating prospect:', err);
    res.status(500).send('Error creating prospect');
  }
});

// --- Chat API Route ---
app.post('/chat', async (req, res) => {
  const { userMessage, chatHistory, prospectId } = req.body;

  if (!prospectId) {
    return res.status(400).json({ error: 'Missing Prospect ID' });
  }

  try {
    // 1. Get the correct AI Brain from the DB
    const brainResult = await pool.query('SELECT system_prompt FROM prospects WHERE unique_id = $1', [prospectId]);
    if (brainResult.rows.length === 0) {
      return res.status(404).json({ error: 'Prospect brain not found' });
    }
    const SYSTEM_PROMPT = brainResult.rows[0].system_prompt;

    // 2. Call OpenRouter for text
    const llmResponse = await axios.post(
      'https://openrouter.ai/api/v1/chat/completions',
      {
        model: process.env.OPENROUTER_MODEL_NAME || 'google/gemini-pro',
        messages: [
          { role: 'system', content: SYSTEM_PROMPT },
          ...chatHistory,
          { role: 'user', content: userMessage },
        ],
      },
      { headers: { Authorization: `Bearer ${process.env.OPENROUTER_API_KEY}` } }
    );
    const textResponse = llmResponse.data.choices[0].message.content;

    // 3. Call Eleven Labs for audio
    const ttsResponse = await axios.post(
      `https://api.elevenlabs.io/v1/text-to-speech/${process.env.ELEVENLABS_VOICE_ID}/stream`,
      { 
        text: textResponse, 
        model_id: 'eleven_multilingual_v2',
        voice_settings: {
          stability: 0.5,
          similarity_boost: 0.75
        }
      },
      {
        headers: { 
          'Content-Type': 'application/json', 
          'xi-api-key': process.env.ELEVENLABS_API_KEY 
        },
        responseType: 'arraybuffer',
      }
    );
    const audioData = Buffer.from(ttsResponse.data).toString('base64');

    // 4. Send both back to the client
    res.json({ textResponse, audioData: `data:audio/mpeg;base64,${audioData}` });
  } catch (error) {
    console.error('Chat API error:', error.response ? error.response.data : error.message);
    res.status(500).json({ error: 'Failed to get AI response' });
  }
});

// --- Database Initialization and Server Start ---
const initializeDatabase = async () => {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS prospects (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        system_prompt TEXT NOT NULL,
        unique_id TEXT NOT NULL UNIQUE
      );
    `);
    console.log('Database table "prospects" is ready.');
  } catch (err) {
    console.error('Error initializing database:', err);
    // On services like Railway, the app might restart. Don't crash the whole app.
    // process.exit(1); 
  }
};

app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);

  // Only try to init DB if the URL is set
  if (process.env.DATABASE_URL) {
    initializeDatabase();
  } else {
    console.warn('DATABASE_URL not set. Skipping database initialization.');
    console.warn('This is normal for local testing. The database will connect when deployed.');
  }
});