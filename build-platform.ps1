# --- WinTech Demo Platform - Full Project Builder Script ---
# This script will create the full folder structure and all 9 project files.

Write-Host "Creating directories 'views' and 'public'..."
New-Item -ItemType Directory -Name "views"
New-Item -ItemType Directory -Name "public"

# --- 1. package.json ---
Write-Host "Writing package.json..."
$fileContent = @'
{
  "name": "wintech-demo-platform",
  "version": "1.0.0",
  "description": "WinTech AI Sales Agent Demo Platform",
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "ejs": "^3.1.10",
    "dotenv": "^16.4.5",
    "axios": "^1.7.2",
    "pg": "^8.11.5",
    "basic-auth": "^2.0.1",
    "uuid": "^9.0.1"
  }
}
'@
Set-Content -Path ".\package.json" -Value $fileContent -Encoding utf8

# --- 2. .env.example ---
Write-Host "Writing .env.example..."
$fileContent = @'
# --- API Keys (Keep these secret) ---
OPENROUTER_API_KEY=YOUR_OPENROUTER_KEY_HERE
ELEVENLABS_API_KEY=YOUR_ELEVENLABS_KEY_HERE
ELEVENLABS_VOICE_ID=YOUR_CHOSEN_VOICE_ID_HERE
OPENROUTER_MODEL_NAME=google/gemini-pro

# --- Database (From Railway or Render) ---
DATABASE_URL=YOUR_POSTGRES_DATABASE_URL_HERE

# --- Admin Login (You create these) ---
ADMIN_USERNAME=your-admin-username
ADMIN_PASSWORD=your-secret-password
'@
Set-Content -Path ".\.env.example" -Value $fileContent -Encoding utf8

# --- 3. .gitignore ---
Write-Host "Writing .gitignore..."
$fileContent = @'
node_modules
.env
'@
Set-Content -Path ".\.gitignore" -Value $fileContent -Encoding utf8

# --- 4. server.js ---
Write-Host "Writing server.js..."
$fileContent = @'
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
  initializeDatabase();
});
'@
Set-Content -Path ".\server.js" -Value $fileContent -Encoding utf8

# --- 5. views/demo.ejs ---
Write-Host "Writing views/demo.ejs..."
$fileContent = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>WinTech AI Demo</title>
  <link rel="stylesheet" href="/style.css">
  <link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@700&family=Lato:wght@400;700&display=swap" rel="stylesheet">
</head>
<body>

  <header class="demo-header">
    <div class="logo-container">
      <img src="[PASTE YOUR BASE64 LOGO STRING HERE]" alt="WinTech Partners Logo">
    </div>
    <h1>A Smarter Way to Grow for <%= prospectName %></h1>
    <p>Talk to the AI assistant in the corner. It's been trained specifically on your business to see how it would handle your customer inquiries.</p>
  </header>

  <main class="demo-main">
    <h2>Why an AI Agent?</h2>
    <div class="metrics">
      <div class="metric-card">
        <h3>78%</h3>
        <p>of customers buy from the first company that responds.</p>
      </div>
      <div class="metric-card">
        <h3>24/7</h3>
        <p>Instant, intelligent answers for your leads, even at 3 AM.</p>
      </div>
      <div class="metric-card">
        <h3>100%</h3>
        <p>of conversations are aimed at one goal: booking a meeting with you.</p>
      </div>
    </div>
  </main>

  <div id="chat-widget" data-prospect-id="<%= prospectId %>">
    <div id="chat-bubble" class="chat-bubble">
      <svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M12 20.25c.966 0 1.898-.19 2.774-.534a.75.75 0 0 0 .426-1.07 11.21 11.21 0 0 1-4.4-4.4.75.75 0 0 0-1.07-.426A9.75 9.75 0 0 0 3 12c0-5.385 4.365-9.75 9.75-9.75s9.75 4.365 9.75 9.75-4.365 9.75-9.75 9.75Z" /></svg>
    </div>
    <div id="chat-window" class="chat-window">
      <div class="chat-header"><h3>AI Sales Assistant</h3><button id="close-chat">&times;</button></div>
      <div id="chat-messages" class="chat-messages">
        <div class="message ai-message">Hello! How can I help you learn about services for <%= prospectName %>?</div>
      </div>
      <div class="chat-input-area"><input type="text" id="chat-input" placeholder="Ask about services..."><button id="send-button">Send</button></div>
    </div>
  </div>
  
  <script src="/app.js"></script>
</body>
</html>
'@
Set-Content -Path ".\views\demo.ejs" -Value $fileContent -Encoding utf8

# --- 6. views/admin_dashboard.ejs ---
Write-Host "Writing views/admin_dashboard.ejs..."
$fileContent = @'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>WinTech Admin</title>
  <link rel="stylesheet" href="/style.css">
  <link href="https://fonts.googleapis.com/css2?family=Montserrat:wght@700&family=Lato:wght@400;700&display=swap" rel="stylesheet">
</head>
<body class="admin-body">

  <header class="admin-header">
    <img src="[PASTE YOUR BASE64 LOGO STRING HERE]" alt="WinTech Partners Logo" class="admin-logo">
    <h1>AI Demo Platform</h1>
  </header>

  <main class="admin-main">
    
    <section class="admin-card">
      <h2>Create New Prospect Demo</h2>
      <form action="/admin/create" method="POST" class="admin-form">
        <div class="form-group">
          <label for="prospectName">Prospect Name</label>
          <input type="text" id="prospectName" name="prospectName" required>
        </div>
        <div class="form-group">
          <label for="systemPrompt">System Prompt (AI Brain)</label>
          <textarea id="systemPrompt" name="systemPrompt" rows="10" placeholder="Paste the AI brain from Gemini here..."></textarea>
        </div>
        <button type="submit" class="btn-primary">Create Demo Link</button>
      </form>
    </section>

    <section class="admin-card">
      <h2>Existing Demo Links</h2>
      <ul class="prospect-list">
        <% prospects.forEach(prospect => { %>
          <li class="prospect-item">
            <strong><%= prospect.name %></strong>
            <input type="text" value="<%= baseUrl %>/?prospect=<%= prospect.unique_id %>" readonly>
          </li>
        <% }) %>
      </ul>
      <small>Note: You can copy the full, shareable link from the box above.</small>
    </section>

  </main>
</body>
</html>
'@
Set-Content -Path ".\views\admin_dashboard.ejs" -Value $fileContent -Encoding utf8

# --- 7. public/style.css ---
Write-Host "Writing public/style.css..."
$fileContent = @'
/* --- Global & WinTech Branding --- */
body {
  font-family: 'Lato', sans-serif;
  line-height: 1.6;
  background-color: #f4f7f6;
  color: #333;
  margin: 0;
  padding: 0;
}
h1, h2, h3 {
  font-family: 'Montserrat', sans-serif;
  color: #1C1C3C; /* Deep Midnight */
}
.btn-primary {
  background-color: #388BEB; /* Win Blue */
  color: #FFFFFF;
  font-family: 'Montserrat', sans-serif;
  font-weight: 700;
  font-size: 1.1rem;
  padding: 0.75rem 1.5rem;
  border: none;
  border-radius: 5px;
  cursor: pointer;
  transition: background-color 0.2s ease;
}
.btn-primary:hover {
  background-color: #935CFF; /* Tech Purple */
}

/* --- Demo Page --- */
.demo-header {
  background: #1C1C3C; /* Deep Midnight */
  color: #FFFFFF;
  padding: 3rem 1rem;
  text-align: center;
}
.demo-header h1 {
  color: #FFFFFF;
  font-size: 2.5rem;
}
.demo-header p {
  font-size: 1.2rem;
  color: #CFCFD4; /* Silver Gray */
  max-width: 600px;
  margin: 1rem auto 0;
}
.logo-container {
  margin-bottom: 2rem;
}
.logo-container img {
  max-width: 250px;
}
.demo-main {
  max-width: 900px;
  margin: 3rem auto;
  padding: 0 1rem;
  text-align: center;
}
.metrics {
  display: flex;
  gap: 1.5rem;
  justify-content: center;
  flex-wrap: wrap;
}
.metric-card {
  background: #FFFFFF;
  border-radius: 8px;
  padding: 2rem;
  box-shadow: 0 4px 12px rgba(0,0,0,0.05);
  flex-basis: 250px;
  border-top: 4px solid #388BEB; /* Win Blue */
}
.metric-card h3 {
  font-size: 3rem;
  color: #935CFF; /* Tech Purple */
  margin: 0 0 0.5rem 0;
}
.metric-card p {
  font-size: 1rem;
  margin: 0;
}

/* --- Admin Page --- */
.admin-body {
  background-color: #f4f7f6; /* Lighter bg for admin */
}
.admin-header {
  background-color: #1C1C3C; /* Deep Midnight */
  text-align: center;
  padding: 1.5rem;
}
.admin-logo {
  max-width: 180px;
}
.admin-header h1 {
  color: #FFFFFF;
  font-size: 1.5rem;
  margin-top: 0.5rem;
}
.admin-main {
  max-width: 800px;
  margin: 2rem auto;
  padding: 0 1rem;
  display: grid;
  gap: 2rem;
}
.admin-card {
  background: #FFFFFF;
  padding: 2rem;
  border-radius: 8px;
  box-shadow: 0 5px 15px rgba(0,0,0,0.1);
}
.admin-form .form-group {
  margin-bottom: 1.5rem;
}
.admin-form label {
  display: block;
  font-weight: 700;
  margin-bottom: 0.5rem;
  color: #333;
}
.admin-form input[type="text"],
.admin-form textarea {
  width: 100%;
  padding: 0.75rem;
  font-family: 'Lato', sans-serif;
  font-size: 1rem;
  border: 1px solid #CFCFD4;
  border-radius: 5px;
  box-sizing: border-box;
}
.prospect-list {
  list-style: none;
  padding: 0;
  margin: 0;
}
.prospect-item {
  background: #f9f9f9;
  padding: 1rem;
  border-radius: 5px;
  margin-bottom: 1rem;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}
.prospect-item input[type="text"] {
  width: 100%;
  padding: 0.5rem;
  border: 1px solid #ddd;
  background: #eee;
  font-family: 'Consolas', monospace;
  box-sizing: border-box;
  color: #333;
}

/* --- Chat Widget (Shared) --- */
#chat-bubble {
  position: fixed;
  bottom: 20px;
  right: 20px;
  width: 60px;
  height: 60px;
  background: #388BEB; /* Win Blue */
  color: white;
  border-radius: 50%;
  display: flex;
  align-items: center;
  justify-content: center;
  cursor: pointer;
  box-shadow: 0 4px 10px rgba(0,0,0,0.2);
  z-index: 9998;
}
#chat-bubble svg { width: 32px; height: 32px; }
#chat-window {
  position: fixed;
  bottom: 90px;
  right: 20px;
  width: 350px;
  max-width: 90vw;
  height: 500px;
  background: #fff;
  border-radius: 12px;
  box-shadow: 0 10px 30px rgba(0,0,0,0.2);
  display: none;
  flex-direction: column;
  overflow: hidden;
  z-index: 9999;
}
#chat-window.open { display: flex; }
.chat-header {
  background: #1C1C3C; /* Deep Midnight */
  color: #FFFFFF;
  padding: 1rem;
  display: flex;
  justify-content: space-between;
  align-items: center;
}
.chat-header h3 { color: #FFFFFF; margin: 0; font-size: 1.1rem; }
#close-chat {
  background: none; border: none; color: #CFCFD4; font-size: 1.5rem; cursor: pointer;
}
.chat-messages {
  flex-grow: 1;
  padding: 1rem;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 0.75rem;
}
.message {
  padding: 0.75rem 1rem;
  border-radius: 18px;
  max-width: 80%;
  line-height: 1.4;
  word-wrap: break-word;
}
.ai-message {
  background: #f1f0f0; color: #333; align-self: flex-start;
}
.user-message {
  background: #388BEB; color: white; align-self: flex-end;
}
.chat-input-area {
  display: flex;
  border-top: 1px solid #ddd;
  padding: 0.5rem;
  background: #fff;
}
#chat-input {
  flex-grow: 1; border: none; padding: 0.75rem; border-radius: 20px;
  background: #f1f0f0; outline: none;
}
#send-button {
  background: #388BEB; color: white; border: none; padding: 0 1rem;
  margin-left: 0.5rem; border-radius: 20px; cursor: pointer;
}
.audio-controls { margin-top: 8px; }
.play-audio-btn {
  background: #eee; border: 1px solid #ddd; border-radius: 50%;
  width: 30px; height: 30px; cursor: pointer;
  display: flex; align-items: center; justify-content: center;
}
.play-audio-btn svg { width: 16px; height: 16px; margin: auto; }
'@
Set-Content -Path ".\public\style.css" -Value $fileContent -Encoding utf8

# --- 8. public/app.js ---
Write-Host "Writing public/app.js..."
$fileContent = @'
document.addEventListener('DOMContentLoaded', () => {
  const chatWidget = document.getElementById('chat-widget');
  if (!chatWidget) return; // Don't run on admin page

  const chatBubble = document.getElementById('chat-bubble');
  const chatWindow = document.getElementById('chat-window');
  const closeChat = document.getElementById('close-chat');
  const chatInput = document.getElementById('chat-input');
  const sendButton = document.getElementById('send-button');
  const chatMessages = document.getElementById('chat-messages');

  // CRITICAL: Get the unique prospect ID from the HTML
  const prospectId = chatWidget.dataset.prospectId;
  let chatHistory = [];
  let currentAudio = null;

  chatBubble.addEventListener('click', () => chatWindow.classList.toggle('open'));
  closeChat.addEventListener('click', () => chatWindow.classList.remove('open'));
  sendButton.addEventListener('click', sendMessage);
  chatInput.addEventListener('keypress', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  });

  async function sendMessage() {
    const userMessage = chatInput.value.trim();
    if (!userMessage) return;

    addMessageToUI(userMessage, 'user');
    chatInput.value = '';
    chatHistory.push({ role: 'user', content: userMessage });

    const loadingEl = addMessageToUI('...', 'ai', null, true);

    try {
      const response = await fetch('/chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          userMessage,
          chatHistory,
          prospectId: prospectId // Send the prospect ID to the backend
        }),
      });

      chatMessages.removeChild(loadingEl);
      if (!response.ok) throw new Error('Network response was not ok');

      const { textResponse, audioData } = await response.json();
      addMessageToUI(textResponse, 'ai', audioData);
      chatHistory.push({ role: 'assistant', content: textResponse });
      playAudio(audioData);

    } catch (error) {
      console.error('Error:', error);
      // Check if loadingEl is still a child before removing
      if(loadingEl.parentNode === chatMessages) {
          chatMessages.removeChild(loadingEl);
      }
      addMessageToUI('Sorry, I am having trouble connecting. Please try again.', 'ai');
    }
  }

  function addMessageToUI(message, sender, audioData = null, isLoading = false) {
    const messageEl = document.createElement('div');
    messageEl.classList.add('message', `${sender}-message`);
    messageEl.textContent = message;
    
    if (isLoading) messageEl.classList.add('loading');

    if (sender === 'ai' && audioData) {
      const audioControls = document.createElement('div');
      audioControls.classList.add('audio-controls');
      const playBtn = document.createElement('button');
      playBtn.classList.add('play-audio-btn');
      playBtn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor"><path stroke-linecap="round" stroke-linejoin="round" d="M5.25 5.653c0-1.426 1.529-2.33 2.779-1.643l11.54 6.348c1.295.712 1.295 2.573 0 3.285L8.029 19.99c-1.25.687-2.779-.217-2.779-1.643V5.653Z" /></svg>`;
      playBtn.onclick = () => playAudio(audioData);
      audioControls.appendChild(playBtn);
      messageEl.appendChild(audioControls);
    }
    
    chatMessages.appendChild(messageEl);
    chatMessages.scrollTop = chatMessages.scrollHeight;
    return messageEl;
  }

  function playAudio(audioData) {
    if (currentAudio) currentAudio.pause();
    currentAudio = new Audio(audioData);
    currentAudio.play();
  }
});
'@
Set-Content -Path ".\public\app.js" -Value $fileContent -Encoding utf8

Write-Host "---"
Write-Host "✅ All 9 project files created successfully!"
Write-Host "---"
Write-Host "NEXT STEPS:"
Write-Host "1. Convert your 'WinTech Logo-Static.png' to a Base64 string."
Write-Host "2. Paste that string into 'views/demo.ejs' and 'views/admin_dashboard.ejs'."
Write-Host "3. Copy '.env.example' to '.env' and fill in your API keys and admin login."
Write-Host "4. Run 'npm install' to install dependencies."
Write-Host "5. Run 'npm start' to test locally."
Write-Host "6. Push to GitHub and deploy to Railway or Render."
Write-Host "---"