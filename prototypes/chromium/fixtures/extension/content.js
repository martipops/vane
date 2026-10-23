chrome.runtime.sendMessage({ type: 'vane-smoke' }, reply => {
  if (chrome.runtime.lastError) {
    document.documentElement.dataset.vaneSmoke = 'error';
  } else {
    document.documentElement.dataset.vaneSmoke = String(reply.visits);
  }
});
