const tabsElement = document.querySelector('#tabs');
const statusElement = document.querySelector('#status');
const browserPiPButton = document.querySelector('#browser-pip');
let pendingRequestId;
let retryButton;

async function startTab(tabId) {
  statusElement.textContent = 'タブの中だけをPiPで表示しています…';
  retryButton.hidden = true;
  pendingRequestId = crypto.randomUUID();
  try {
    const result = await chrome.runtime.sendMessage({
      target: 'background', action: 'captureTab', tabId, requestId: pendingRequestId
    });
    if (!result?.ok) throw new Error(result?.error || '拡張機能に接続できませんでした。');
  } catch (error) {
    statusElement.textContent = error.message;
    retryButton.hidden = false;
  }
}

chrome.runtime.onMessage.addListener(message => {
  if (message?.target !== 'popup' || message.requestId !== pendingRequestId) return;
  if (message.action === 'captureTabStarted') {
    statusElement.textContent = 'このタブの中だけをPiPで表示しました。';
    setTimeout(() => window.close(), 500);
  } else if (message.action === 'captureTabError') {
    statusElement.textContent = message.error;
    if (retryButton) retryButton.hidden = false;
  }
});

browserPiPButton.addEventListener('click', async () => {
  statusElement.textContent = 'PiPを開始しています…';
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab?.id) {
    statusElement.textContent = '現在のタブを取得できませんでした。';
    return;
  }
  try {
    await chrome.runtime.sendMessage({ target: 'background', action: 'stopTabCapture' });
    const results = await chrome.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      world: 'MAIN',
      func: async () => {
        const videos = [...document.querySelectorAll('video')]
          .filter(video => video.readyState > 0 && video.videoWidth > 0 && video.videoHeight > 0)
          .sort((a, b) => (b.clientWidth * b.clientHeight) - (a.clientWidth * a.clientHeight));
        const video = videos[0];
        if (!video) return { ok: false, reason: 'video-not-found' };
        if (!document.pictureInPictureEnabled || video.disablePictureInPicture) {
          return { ok: false, reason: 'disabled' };
        }
        try {
          await video.requestPictureInPicture();
          return { ok: true };
        } catch (error) {
          return { ok: false, reason: error.name || 'failed' };
        }
      }
    });
    const result = results.find(item => item.result?.ok)?.result;
    if (result?.ok) {
      statusElement.textContent = 'PiPを開始しました';
      setTimeout(() => window.close(), 500);
    } else {
      const reason = results.find(item => item.result?.reason)?.result?.reason;
      statusElement.textContent = reason === 'disabled'
        ? 'このサイトは動画PiPを許可していません。'
        : '再生中の動画が見つからないか、PiPを開始できませんでした。';
    }
  } catch (error) {
    statusElement.textContent = `PiPを開始できませんでした: ${error.message}`;
  }
});

async function loadTabs() {
  // Opening this popup grants activeTab only for the tab the user invoked it on.
  // Do not offer unrelated tabs and silently switch to or capture them.
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  for (const tab of tabs.filter(tab => tab.title && tab.id !== undefined)) {
    const title = document.createElement('p');
    title.textContent = tab.title;
    tabsElement.appendChild(title);
    retryButton = document.createElement('button');
    retryButton.textContent = '再試行';
    retryButton.hidden = true;
    retryButton.addEventListener('click', () => startTab(tab.id));
    tabsElement.appendChild(retryButton);
    const url = new URL(tab.url || 'about:blank');
    const protectedVideo = /(^|\.)netflix\.com$|(^|\.)primevideo\.com$/.test(url.hostname) ||
      (/(^|\.)amazon\./.test(url.hostname) && url.pathname.includes('/video'));
    if (protectedVideo) {
      statusElement.textContent = '保護動画は下の「現在の動画をPiPで表示」を使ってください。';
    } else {
      // Opening the toolbar action is the user invocation; no second click needed.
      await startTab(tab.id);
    }
  }
}

loadTabs().catch(error => { statusElement.textContent = error.message; });

