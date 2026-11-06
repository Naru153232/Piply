let port;
let pollTimer;
let tabsTimer;
const captureSessions = new Map();
const permissionIntents = new Map();
let commandQueue = Promise.resolve();
const VIDEO_PIP_MENU_ID = 'piply-video';
const VIDEO_PIP_ADD_MENU_ID = 'piply-video-add';

async function installVideoContextMenu() {
  await chrome.contextMenus.removeAll();
  chrome.contextMenus.create({
    id: VIDEO_PIP_MENU_ID,
    title: '動画をPiPで表示',
    contexts: ['video']
  });
  chrome.contextMenus.create({ id: VIDEO_PIP_ADD_MENU_ID,
    title: '動画を新しいPiPタブに追加', contexts: ['video'] });
}


async function showPiPResult(result) {
  const succeeded = Boolean(result?.ok);
  await chrome.action.setBadgeBackgroundColor({ color: succeeded ? '#1f9d55' : '#d93025' });
  await chrome.action.setBadgeText({ text: succeeded ? '✓' : '!' });
  await chrome.action.setTitle({
    title: succeeded
      ? '動画をPiPで表示しました'
      : result?.reason === 'disabled'
        ? 'このサイトでは動画PiPが無効です'
        : (result?.error || '動画をPiPで表示できませんでした')
  });
  setTimeout(() => {
    chrome.action.setBadgeText({ text: '' });
    chrome.action.setTitle({ title: 'Piply' });
  }, 4000);
}

function connect() {
  if (port) return;
  port = chrome.runtime.connectNative('com.naru.piply');
  port.onMessage.addListener(response => {
    if (response?.command) enqueueCommand(response.command);
    if (response?.ok === false && captureSessions.has(response.requestId)) {
      const session = captureSessions.get(response.requestId);
      notifyPopup(session, 'captureTabError', { error: response.error });
      chrome.action.setBadgeText({ tabId: session.tabId, text: '!' }).catch(() => {});
      chrome.action.setTitle({ tabId: session.tabId, title: response.error || 'アプリを起動できませんでした' }).catch(() => {});
      enqueueCommand({ action: 'stopTabCapture', requestId: session.requestId });
    }
  });
  port.onDisconnect.addListener(() => {
    port = undefined;
    clearInterval(pollTimer);
    clearInterval(tabsTimer);
    // A temporary helper disconnect is not a user closing a PiP tab.
    // Keep media peers and their slot identities while reconnecting control.
    setTimeout(connect, 1500);
  });
  publishTabs();
  for (const session of captureSessions.values()) {
    if (session.videoTarget && !session.hasFrame && session.documentId) {
      chrome.tabs.sendMessage(session.tabId, { target: 'video-element', action: 'stop',
        requestId: session.requestId }, { documentId: session.documentId }).catch(() => {});
      videoWaiting(session);
    }
  }
  pollTimer = setInterval(() => send({ action: 'poll' }), 100);
  tabsTimer = setInterval(publishTabs, 3000);
}

function send(message) {
  try { port?.postMessage(message); } catch (_) { port = undefined; }
}

async function publishTabs() {
  const tabs = await chrome.tabs.query({});
  send({ action: 'syncTabs', extensionVersion: chrome.runtime.getManifest().version, tabs: tabs.filter(tab => tab.id !== undefined).map(tab => ({
    id: tab.id, windowId: tab.windowId, title: tab.title || tab.url || '無題のタブ',
    url: tab.url || null, active: Boolean(tab.active)
  })) });
}

function enqueueCommand(command) {
  commandQueue = commandQueue.then(() => {
    if (command.action === 'captureTab') return captureTab(command.tabId, command.requestId, command.allowFocusForPermission === true, command.videoTarget, command.addAsTab === true);
    if (command.action === 'stopTabCapture') return stopTabCapture(command.tabId, command.requestId);
    const captureSession = captureSessions.get(command.requestId);
    if (command.action === 'restartVideo' && captureSession?.videoTarget &&
        captureSession.tabId === command.tabId && captureSession.streamId === command.streamId) {
      return chrome.tabs.sendMessage(captureSession.tabId,
        { target: 'video-element', action: 'stop', requestId: command.requestId },
        { documentId: captureSession.documentId }).catch(() => {});
    }
    if (command.action === 'streamAnswer'  && captureSession?.tabId === command.tabId) {
      if (captureSession.videoTarget && command.streamId !== captureSession.streamId) return;
      if (captureSession.videoTarget) return chrome.tabs.sendMessage(captureSession.tabId,
        { target: 'video-element', action: 'answer', requestId: command.requestId, sdp: command.sdp, streamId: command.streamId },
        { documentId: captureSession.documentId });
      return chrome.runtime.sendMessage({ ...command, target: 'offscreen', action: 'answer' });
    }
  }).catch(error => console.error('PiP command failed:', error));
  return commandQueue;
}

function captureMessage(session, action, extra = {}) {
  return {
    action, tabId: session.tabId, requestId: session.requestId,
    title: session.tab?.title || 'Google Chrome', addAsTab: session.addAsTab === true, ...extra
  };
}

function streamReady(session) {
  if (captureSessions.get(session.requestId) !== session) return;
  if (!session.hasFrame) {
    session.hasFrame = true;
    clearTimeout(session.timeout);
    // Success means an actual frame has been received, not just an accepted command.
    notifyPopup(session, 'captureTabStarted');
  }
}

function notifyPopup(session, action, extra = {}) {
  chrome.runtime.sendMessage({ target: 'popup', ...captureMessage(session, action, extra) }).catch(() => {});
}

function reportCaptureError(session, error) {
  send(captureMessage(session, 'captureTabError', { error }));
  notifyPopup(session, 'captureTabError', { error });
}

async function ensureOffscreenDocument() {
  const contexts = await chrome.runtime.getContexts({
    contextTypes: ['OFFSCREEN_DOCUMENT'],
    documentUrls: [chrome.runtime.getURL('offscreen.html')]
  });
  if (contexts.length) return;
  await chrome.offscreen.createDocument({
    url: 'offscreen.html', reasons: ['USER_MEDIA'],
    justification: '選択された1つのタブの映像をPiplyへ送るため'
  });
}

async function revealTabForPermission(session, message) {
  permissionIntents.set(session.tabId, { addAsTab: session.addAsTab, expires: Date.now() + 120000 });
  const tab = await chrome.tabs.update(session.tabId, { active: true });
  const window = await chrome.windows.get(tab.windowId);
  await chrome.windows.update(tab.windowId, {
    focused: true,
    ...(window.state === 'minimized' ? { state: 'normal' } : {})
  });
  // A real click on the extension action is still required to grant activeTab.
  // Opening a popup programmatically would not grant it, so do not simulate one.
  await chrome.action.setBadgeBackgroundColor({ tabId: session.tabId, color: '#315efb' }).catch(() => {});
  await chrome.action.setBadgeText({ tabId: session.tabId, text: 'PiP' }).catch(() => {});
  await chrome.action.setTitle({ tabId: session.tabId, title: 'ここを1回押すと、このタブをPiPで表示します' }).catch(() => {});
  send(captureMessage(session, 'captureTabNeedsPermission', { error: message }));
  await stopTabCapture(session.tabId, session.requestId);
  return { ok: false, needsPermission: true, error: message };
}

function videoWaiting(session, error) {
  clearTimeout(session.timeout);
  send(captureMessage(session, 'videoWaiting', { streamId: session.streamId, error }));
}

async function attachVideoSender(session, onlyIfNewFrame = false) {
  if (captureSessions.get(session.requestId) !== session) return;
  let frameId = session.videoTarget.frameId;
  // On navigation the previous document/frame may no longer exist. Inspect
  // accessible frames only; activeTab permissions are never bypassed.
  if (session.attachedOnce) {
    const frames = await chrome.scripting.executeScript({
      target: { tabId: session.tabId, allFrames: true },
      func: () => {
        const videos = [...document.querySelectorAll('video')].filter(video => !video.ended && video.readyState >= 2 && video.videoWidth > 0);
        return videos.reduce((score, video) => {
          const rect = video.getBoundingClientRect();
          return Math.max(score, (video.paused ? 0 : 1e9) + rect.width * rect.height);
        }, 0);
      }
    });
    frames.sort((a, b) => (b.result || 0) - (a.result || 0));
    frameId = frames.find(frame => frame.result > 0)?.frameId ?? 0;
    if (onlyIfNewFrame && (!frames.some(frame => frame.result > 0) || frameId === session.videoTarget.frameId)) return;
  }
  if (captureSessions.get(session.requestId) !== session) return;
  if (onlyIfNewFrame && session.documentId) {
    await chrome.tabs.sendMessage(session.tabId, { target: 'video-element', action: 'stop',
      requestId: session.requestId }, { documentId: session.documentId }).catch(() => {});
    videoWaiting(session);
  }
  const [injection] = await chrome.scripting.executeScript({
    target: { tabId: session.tabId, frameIds: [frameId] }, files: ['video-element.js']
  });
  if (captureSessions.get(session.requestId) !== session) return;
  if (!injection?.documentId) throw new Error('動画のページへの接続を待っています。');
  session.documentId = injection.documentId;
  session.videoTarget.frameId = frameId;
  session.streamId = undefined;
  session.attachedOnce = true;
  const response = await chrome.tabs.sendMessage(session.tabId, {
    target: 'video-element', action: 'start', requestId: session.requestId,
    sourceURL: session.videoTarget.sourceURL
  }, { documentId: session.documentId });
  if (captureSessions.get(session.requestId) !== session) {
    await chrome.tabs.sendMessage(session.tabId, { target: 'video-element', action: 'stop',
      requestId: session.requestId }, { documentId: session.documentId }).catch(() => {});
    return;
  }
  session.videoTarget.sourceURL = '';
  if (!response?.ok) throw new Error(response?.error || '動画の再接続を待っています。');
}

async function watchVideoTab(session) {
  if (captureSessions.get(session.requestId) !== session) return;
  try {
    session.tab = await chrome.tabs.get(session.tabId);
    let active = false, available = false;
    if (session.documentId) {
      const response = await chrome.tabs.sendMessage(session.tabId,
        { target: 'video-element', action: 'ping', requestId: session.requestId },
        { documentId: session.documentId }).catch(() => null);
      active = response?.active === true;
      available = response?.available === true;
    }
    if (!active && captureSessions.get(session.requestId) === session) {
      videoWaiting(session);
      await attachVideoSender(session);
    } else if (active && !available && captureSessions.get(session.requestId) === session) {
      await attachVideoSender(session, true);
    }
  } catch (error) {
    if (captureSessions.get(session.requestId) === session)
      videoWaiting(session, '動画を待っています。ページへのアクセス許可が失われた場合は、Chromeの動画メニューから再接続してください。');
  } finally {
    if (captureSessions.get(session.requestId) === session)
      session.videoTimer = setTimeout(() => watchVideoTab(session), 2000);
  }
}

async function captureTab(tabId, requestId = crypto.randomUUID(), allowFocusForPermission = false, videoTarget, addAsTab = false) {
  const existing = [...captureSessions.values()].find(session => session.tabId === Number(tabId));
  if (existing && videoTarget && existing.videoTarget) {
    existing.videoTarget.sourceURL = videoTarget.sourceURL;
    await chrome.tabs.sendMessage(existing.tabId, { target: 'video-element', action: 'stop',
      requestId: existing.requestId }, { documentId: existing.documentId }).catch(() => {});
    videoWaiting(existing);
    send(captureMessage(existing, 'selectPiPTab'));
    return { ok: true, requestId: existing.requestId };
  }
  // Three retained PiP tabs plus one temporary replacement handshake.
  if (captureSessions.size >= 4) {
    const error = 'PiPの接続数が上限に達しました。不要なタブを削除してください。';
    reportCaptureError({ tabId: Number(tabId), requestId }, error);
    return { ok: false, error };
  }
  const session = { tabId: Number(tabId), requestId, hasFrame: false, videoTarget, addAsTab };
  captureSessions.set(requestId, session);
  try {
    const tab = await chrome.tabs.get(session.tabId);
    session.tab = tab;
    if (!/^https?:/.test(tab.url || '')) throw new Error('このChrome内部ページは取得できません。通常のWebページを選んでください。');
    if (tab.discarded) {
      if (allowFocusForPermission) {
        return await revealTabForPermission(session, '休止中のタブを開きました。読み込み後、ChromeのPiplyアイコンを1回押すと開始します。');
      }
      throw new Error('このタブはメモリ節約のため休止中です。一度Chromeで読み込んでから選んでください。');
    }
    if (videoTarget) {
      try { await attachVideoSender(session); }
      catch (error) { videoWaiting(session, error?.message || String(error)); }
      session.videoTimer = setTimeout(() => watchVideoTab(session), 2000);
      return { ok: true, requestId };
    }
    session.viewport = await readViewport(tab);
    await ensureOffscreenDocument();
    let streamId;
    try {
      // Try direct capture first. Only a native-app request may reveal the
      // selected tab when Chrome reports that user invocation is missing.
      // Never fall back to debugger or window/screen capture.
      streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: session.tabId });
    } catch (error) {
      const reason = error?.message || String(error);
      if (allowFocusForPermission && /not been invoked|activeTab/i.test(reason)) {
        return await revealTabForPermission(session, '選んだタブへ移動しました。ChromeのPiplyアイコン（PiPの目印）を1回押すと、そのタブの中だけを表示します。');
      }
      throw new Error(`タブの取得を開始できませんでした。未許可の場合は対象タブで拡張機能アイコンを1回押してください。Chrome: ${reason}`);
    }
    await chrome.action.setBadgeText({ tabId: session.tabId, text: '' }).catch(() => {});
    permissionIntents.delete(session.tabId);
    await chrome.action.setTitle({ tabId: session.tabId, title: 'Piply' }).catch(() => {});
    session.timeout = setTimeout(() => {
      if (captureSessions.get(session.requestId) !== session || session.hasFrame) return;
      reportCaptureError(session, 'タブから画像が届きませんでした。取得を停止します。対象タブの拡張機能から再度開始してください。');
      enqueueCommand({ action: 'stopTabCapture', requestId: session.requestId });
    }, 25000);
    const response = await chrome.runtime.sendMessage({
      target: 'offscreen', action: 'start', streamId,
      tabId: session.tabId, requestId: session.requestId,
      viewport: session.viewport
    });
    if (!response?.ok) throw new Error('タブ映像の受信ページを開始できませんでした。');
    session.sizeTimer = setTimeout(() => updateViewport(session), 250);
    return { ok: true, requestId };
  } catch (error) {
    const reason = error?.message || String(error);
    reportCaptureError(session, reason);
    await stopTabCapture(session.tabId, session.requestId);
    return { ok: false, error: reason };
  }
}

async function readViewport(tab) {
  try {
    // Read only the selected top-level tab's dimensions. This also handles page
    // zoom and responsive viewports without activating the tab or attaching DevTools.
    const [result] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => ({ width: window.innerWidth, height: window.innerHeight, pixelRatio: window.devicePixelRatio })
    });
    if (result?.result?.width > 0 && result?.result?.height > 0) return result.result;
  } catch (_) { /* activeTab can expire on navigation; WebContents bounds remain available. */ }
  return { width: tab.width, height: tab.height };
}

async function updateViewport(session) {
  if (captureSessions.get(session.requestId) !== session) return;
  try {
    const tab = await chrome.tabs.get(session.tabId);
    const viewport = await readViewport(tab);
    if (captureSessions.get(session.requestId) !== session) return;
    if (viewport.width > 0 && viewport.height > 0 &&
        JSON.stringify(viewport) !== JSON.stringify(session.viewport)) {
      session.viewport = viewport;
      await chrome.runtime.sendMessage({
        target: 'offscreen', action: 'viewport', tabId: session.tabId,
        requestId: session.requestId, viewport: session.viewport
      });
    }
  } catch (_) { /* Tab closure is handled by onRemoved / the media track. */ }
  if (captureSessions.get(session.requestId) === session) session.sizeTimer = setTimeout(() => updateViewport(session), 250);
}

async function stopTabCapture(requestedTabId, requestId) {
  if (!requestId) {
    for (const session of [...captureSessions.values()]) {
      if (requestedTabId === undefined || Number(requestedTabId) === session.tabId) await stopTabCapture(session.tabId, session.requestId);
    }
    return;
  }
  const session = captureSessions.get(requestId);
  if (!session) return;
  if (requestedTabId !== undefined && Number(requestedTabId) !== session.tabId) return;
  if (requestId !== undefined && requestId !== session.requestId) return;
  captureSessions.delete(session.requestId);
  clearTimeout(session.timeout);
  clearTimeout(session.sizeTimer);
  clearTimeout(session.videoTimer);
  try {
    if (session.videoTarget && session.documentId) {
      await chrome.tabs.sendMessage(session.tabId,
        { target: 'video-element', action: 'stop', requestId: session.requestId },
        { documentId: session.documentId });
    } else if (!session.videoTarget) {
      await chrome.runtime.sendMessage({ target: 'offscreen', action: 'stop', requestId: session.requestId });
    }
  } catch (_) {}
  send(captureMessage(session, 'tabCaptureStopped'));
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || message?.target !== 'background') return;
  if (message.source === 'video-element') {
    const session = captureSessions.get(message.requestId);
    if (!session?.videoTarget || session.requestId !== message.requestId ||
        sender.tab?.id !== session.tabId || sender.documentId !== session.documentId ||
        sender.frameId !== session.videoTarget.frameId) return;
    if (message.action === 'offer') {
      session.streamId = message.streamId;
      send(captureMessage(session, 'streamOffer', {
        sdp: message.sdp, viewportWidth: message.width, viewportHeight: message.height,
        streamId: message.streamId, videoElement: true
      }));
    }
    if (message.streamId && session.streamId && message.streamId !== session.streamId) return;
    if (message.action === 'ready') streamReady(session);
    if (message.action === 'availability' && !message.available || message.action === 'waiting')
      videoWaiting(session, message.error);
    return;
  }
  if (sender.url === chrome.runtime.getURL('offscreen.html')) {
    const session = captureSessions.get(message.requestId);
    if (!session || session.videoTarget || message.requestId !== session.requestId || message.tabId !== session.tabId) return;
    if (message.action === 'offer') send(captureMessage(session, 'streamOffer', {
      sdp: message.sdp, viewportWidth: session.viewport.width, viewportHeight: session.viewport.height
    }));
    if (message.action === 'ready') streamReady(session);
    if (message.action === 'error') {
      reportCaptureError(session, message.error || 'タブの映像取得が終了しました。');
      enqueueCommand({ action: 'stopTabCapture', requestId: session.requestId });
    }
    return;
  }
  if (sender.url !== chrome.runtime.getURL('popup.html')) return;
  if (message.action === 'captureTab' || message.action === 'stopTabCapture') {
    // The popup acts on the user's current tab and must not move other windows.
    enqueueCommand({ ...message, allowFocusForPermission: false }).then(result => sendResponse(result || { ok: true }));
    return true;
  }
});
// A toolbar click is the user invocation for tabCapture; no popup or second click.
chrome.action.onClicked.addListener(async tab => {
  if (!Number.isInteger(tab?.id)) return;
  try {
    connect();
    const result = await enqueueCommand({
      action: 'captureTab', tabId: tab.id, requestId: crypto.randomUUID(),
      addAsTab: (permissionIntents.get(tab.id)?.expires > Date.now()) && permissionIntents.get(tab.id)?.addAsTab === true,
      allowFocusForPermission: false
    });
    if (!result?.ok) {
      await chrome.action.setBadgeBackgroundColor({ tabId: tab.id, color: '#d93025' });
      await chrome.action.setBadgeText({ tabId: tab.id, text: '!' });
      await chrome.action.setTitle({ tabId: tab.id, title: result?.error || 'PiPを開始できませんでした' });
    }
  } catch (error) {
    await chrome.action.setTitle({ tabId: tab.id, title: error?.message || 'PiPを開始できませんでした' });
  }
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  if (![VIDEO_PIP_MENU_ID, VIDEO_PIP_ADD_MENU_ID].includes(info.menuItemId) || !tab?.id) return;
  try {
    connect();
    const result = await enqueueCommand({ action: 'captureTab', tabId: tab.id,
      addAsTab: info.menuItemId === VIDEO_PIP_ADD_MENU_ID,
      requestId: crypto.randomUUID(), videoTarget: { frameId: info.frameId || 0, sourceURL: info.srcUrl || '' } });
    await showPiPResult(result);
  } catch (error) {
    await showPiPResult({ ok: false, reason: error?.name || 'failed' });
  }
});
chrome.tabs.onCreated.addListener(publishTabs);
chrome.tabs.onRemoved.addListener(tabId => {
  permissionIntents.delete(tabId);
  for (const session of captureSessions.values()) {
    if (session.tabId !== tabId) continue;
    send(captureMessage(session, 'sourceTabClosed'));
    enqueueCommand({ action: 'stopTabCapture', tabId, requestId: session.requestId });
  }
  publishTabs();
});
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.status === 'loading') {
    for (const session of captureSessions.values()) {
      if (session.tabId === tabId && session.videoTarget) videoWaiting(session);
    }
  }
  publishTabs();
});
chrome.tabs.onMoved.addListener(publishTabs);
chrome.tabs.onActivated.addListener(publishTabs);
chrome.windows.onRemoved.addListener(publishTabs);
chrome.runtime.onInstalled.addListener(installVideoContextMenu);
chrome.runtime.onStartup.addListener(installVideoContextMenu);
connect();
