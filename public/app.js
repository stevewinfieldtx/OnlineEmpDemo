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
