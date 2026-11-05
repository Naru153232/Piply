// One selected tab, one video-only WebRTC stream. No JPEG or media files.
const sessions = new Map();

function releaseSession(session) {
  clearTimeout(session.disconnectTimer);
  clearTimeout(session.resizeTimer);
  clearInterval(session.statsTimer);
  session.peer?.close();
  for (const track of session.stream?.getTracks() || []) track.stop();
}
function stop(requestId) {
  const targets = requestId ? [sessions.get(requestId)].filter(Boolean) : [...sessions.values()];
  for (const session of targets) {
    sessions.delete(session.requestId); releaseSession(session);
  }
}
function send(session, action, extra = {}) {
  return chrome.runtime.sendMessage({
    target: 'background', action, tabId: session.tabId, requestId: session.requestId, ...extra
  });
}
function fail(session, error) {
  if (sessions.get(session.requestId) !== session) return;
  send(session, 'error', { error: error?.message || String(error) }).catch(() => {});
  stop(session.requestId);
}
function iceComplete(peer) {
  if (peer.iceGatheringState === 'complete') return Promise.resolve();
  return new Promise((resolve, reject) => {
    let settleTimer;
    const timer = setTimeout(() => finish(new Error('映像接続の準備がタイムアウトしました。')), 8000);
    function candidate(event) {
      // Both peers are local. Allow a short window for interface candidates,
      // rather than waiting for every network interface to finish gathering.
      if (event.candidate && !settleTimer) settleTimer = setTimeout(() => finish(), 250);
    }
    function changed() { if (peer.iceGatheringState === 'complete') finish(); }
    function finish(error) {
      clearTimeout(timer);
      clearTimeout(settleTimer);
      peer.removeEventListener('icecandidate', candidate);
      peer.removeEventListener('icegatheringstatechange', changed);
      error ? reject(error) : resolve();
    }
    peer.addEventListener('icegatheringstatechange', changed);
    peer.addEventListener('icecandidate', candidate);
    changed();
  });
}
function sendViewport(session) {
  if (session.channel?.readyState === 'open')
    session.channel.send(JSON.stringify({ action: 'viewport', ...session.viewport }));
}
// Serialize constraints and coalesce resize events; never queue old sizes.
function scheduleResolution(session) {
  clearTimeout(session.resizeTimer);
  session.resizeTimer = setTimeout(() => updateResolution(session), 180);
}
async function updateResolution(session) {
  if (sessions.get(session.requestId) !== session || session.resizing) return;
  const originalViewport = session.viewport;
  const wasVisible = session.isVisible;
  const viewport = originalViewport || {};
  const sourceWidth = Math.max(1, viewport.width || 1920);
  const sourceHeight = Math.max(1, viewport.height || 1080);
  const sourceScale = Math.max(1, viewport.pixelRatio || 1);
  const target = session.display || { width: 1280, height: 720 };
  // Preserve the tab aspect ratio, including portrait tabs, at display density.
  const scale = Math.min(sourceScale, 3840 / sourceWidth, 2160 / sourceHeight,
    Math.max(target.width / sourceWidth, target.height / sourceHeight));
  const width = Math.max(2, Math.round(sourceWidth * scale / 2) * 2);
  const height = Math.max(2, Math.round(sourceHeight * scale / 2) * 2);
  const key = `${width}:${height}:${session.isVisible !== false}`;
  if (session.resolution === key) return;
  session.resizing = true;
  try {
    if (session.sender) {
      const parameters = session.sender.getParameters();
      if (parameters.encodings?.length) {
        parameters.encodings[0].active = session.isVisible !== false;
        await session.sender.setParameters(parameters);
      }
    }
    if (session.isVisible !== false) await session.track.applyConstraints({
      width: { ideal: width }, height: { ideal: height },
      frameRate: { ideal: 60, max: 60 }
    });
    session.resolution = key;
  } catch (error) {
    console.warn('PiP resolution adjustment failed', error);
  } finally {
    session.resizing = false;
    if (sessions.get(session.requestId) === session && (session.display !== target || session.viewport !== originalViewport || session.isVisible !== wasVisible)) scheduleResolution(session);
  }
}
async function start(message) {
  stop(message.requestId);
  const session = { tabId: message.tabId, requestId: message.requestId, viewport: message.viewport };
  sessions.set(session.requestId, session);
  try {
    session.stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { mandatory: {
        chromeMediaSource: 'tab', chromeMediaSourceId: message.streamId,
        minWidth: 1, minHeight: 1, maxWidth: 3840, maxHeight: 2160, maxFrameRate: 60
      } }
    });
    if (sessions.get(session.requestId) !== session) { releaseSession(session); return; }
    const track = session.stream.getVideoTracks()[0];
    if (!track || track.readyState === 'ended') throw new Error('タブの映像トラックがありません。');
    session.track = track;
    session.display = { width: 1280, height: 720 };
    await updateResolution(session);
    if (sessions.get(session.requestId) !== session) return;
    track.contentHint = 'motion';
    track.addEventListener('ended', () => fail(session, new Error('Chromeでタブの共有が停止されました。')));
    // No external STUN/TURN servers: both peers are on this Mac.
    const peer = session.peer = new RTCPeerConnection({ iceServers: [] });
    const sender = session.sender = peer.addTrack(track, session.stream);
    const parameters = sender.getParameters();
    parameters.degradationPreference = 'maintain-framerate';
    if (parameters.encodings?.length) {
      parameters.encodings[0].maxBitrate = 40000000;
      parameters.encodings[0].scaleResolutionDownBy = 1;
      parameters.encodings[0].maxFramerate = 60;
      await sender.setParameters(parameters);
    }
    const channel = session.channel = peer.createDataChannel('viewport');
    channel.onopen = () => sendViewport(session);
    channel.onmessage = event => {
      if (sessions.get(session.requestId) !== session) return;
      try {
        const data = JSON.parse(event.data);
        if (data.action === 'presentation' && typeof data.active === 'boolean') {
          session.isVisible = data.active;
          scheduleResolution(session);
        }
        if (data.action === 'ready') send(session, 'ready').catch(() => {});
        if (data.action === 'displaySize' && Number.isFinite(data.width) && Number.isFinite(data.height)
            && data.width > 0 && data.height > 0) {
          session.display = { width: Math.min(7680, data.width), height: Math.min(7680, data.height) };
          scheduleResolution(session);
        }
      } catch (_) {}
    };
    let previousStats;
    session.statsTimer = setInterval(async () => {
      try {
        const stats = await sender.getStats();
        if (sessions.get(session.requestId) !== session) return;
        stats.forEach(report => {
          if (report.type !== 'outbound-rtp' || report.kind !== 'video') return;
          const frames = report.framesEncoded - (previousStats?.framesEncoded || 0);
          console.debug('PiP encoder', {
            fps: report.framesPerSecond, width: report.frameWidth, height: report.frameHeight,
            limitation: report.qualityLimitationReason,
            encodeMs: frames > 0 && previousStats
              ? 1000 * (report.totalEncodeTime - previousStats.totalEncodeTime) / frames : null
          });
          previousStats = report;
        });
      } catch (_) {}
    }, 3000);
    peer.onconnectionstatechange = () => {
      clearTimeout(session.disconnectTimer);
      if (peer.connectionState === 'failed') fail(session, new Error('タブ映像の接続が失われました。'));
      if (peer.connectionState === 'disconnected')
        session.disconnectTimer = setTimeout(() => fail(session, new Error('タブ映像の接続が切れました。')), 5000);
    };
    await peer.setLocalDescription(await peer.createOffer());
    await iceComplete(peer);
    if (sessions.get(session.requestId) === session) await send(session, 'offer', { sdp: peer.localDescription.sdp });
  } catch (error) { fail(session, error); }
}
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (sender.id !== chrome.runtime.id || message?.target !== 'offscreen') return;
  if (message.action === 'start') {
    start(message); sendResponse({ ok: true });
  } else if (message.action === 'stop') {
    stop(message.requestId); sendResponse({ ok: true });
  } else if (sessions.get(message.requestId)?.tabId === message.tabId) {
    const session = sessions.get(message.requestId);
    if (message.action === 'answer') {
      session.peer.setRemoteDescription({ type: 'answer', sdp: message.sdp })
        .then(() => sendResponse({ ok: true }))
        .catch(error => { fail(session, error); sendResponse({ ok: false }); });
      return true;
    }
    if (message.action === 'viewport') {
      session.viewport = message.viewport; sendViewport(session); sendResponse({ ok: true });
      scheduleResolution(session);
    }
  }
});
window.addEventListener('pagehide', () => stop());
