chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message.type !== 'vane-smoke' || !sender.url?.startsWith('http://127.0.0.1:')) return;
  chrome.storage.local.get({ visits: 0 }).then(async ({ visits }) => {
    await chrome.storage.local.set({ visits: visits + 1 });
    reply({ visits: visits + 1 });
  });
  return true;
});
