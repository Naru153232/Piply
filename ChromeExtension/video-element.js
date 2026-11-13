// Runs in the extension's isolated world, in only the selected frame.
// The video element's media output is sent directly to the native receiver.
// No tabCapture, canvas, DOM cropping, page messaging, or audio forwarding.
(() => {
  if (globalThis.__piplyVideoSenderInstalled) return;
  globalThis.__piplyVideoSenderInstalled = true;
  const sessions = new Map();

  function notify(session, action, extra = {}) {
    return chrome.runtime.sendMessage({ target: 'background', source: 'video-element',
      requestId: session.requestId, streamId: session.streamId, action, ...extra }).catch(() => {});
  }
  function stop(requestId) {
    if (!requestId) { for (const id of [...sessions.keys()]) stop(id); return; }
    const session = sessions.get(requestId);
    if (!session) return;
    sessions.delete(requestId);
    clearInterval(session.healthTimer);
    clearTimeout(session.disconnectTimer);
    clearTimeout(session.resizeTimer);
    clearTimeout(session.refreshTimer);
    session.observer?.disconnect();
    session.resizeObserver?.disconnect();
    session.cancelICE?.();
    session.events?.abort();
    session.videoEvents?.abort();
    session.peer?.close();
    session.stream?.getTracks().forEach(track => track.stop());
  }
  function fail(session, error) {
    if (sessions.get(session.requestId) !== session) return;
    notify(session, 'waiting', { error: error?.message || String(error) });
    stop(session.requestId);
  }
  function state(session) {
    if (session.fallback) {
      notifyGeometry(session);
      return;
    }
    if (sessions.get(session.requestId) !== session || session.channel?.readyState !== 'open') return;
    const video = session.video;
    if (!video || !session.available) {
      session.channel.send(JSON.stringify({ action: 'videoAvailability', available: false }));
      return;
    }
    session.channel.send(JSON.stringify({ action: 'viewport',
      width: video.videoWidth, height: video.videoHeight,
      video: { paused: video.paused, muted: video.muted,
        currentTime: Number.isFinite(video.currentTime) ? video.currentTime : 0,
        duration: Number.isFinite(video.duration) ? video.duration : null,
        seekStart: video.seekable.length ? video.seekable.start(0) : null,
        seekEnd: video.seekable.length ? video.seekable.end(video.seekable.length - 1) : null } }));
  }
  function videoState(video) {
    return { paused: video.paused, muted: video.muted,
      currentTime: Number.isFinite(video.currentTime) ? video.currentTime : 0,
      duration: Number.isFinite(video.duration) ? video.duration : null,
      seekStart: video.seekable.length ? video.seekable.start(0) : null,
      seekEnd: video.seekable.length ? video.seekable.end(video.seekable.length - 1) : null };
  }
  function geometry(video) {
    const rect = video.getBoundingClientRect();
    const left = Math.max(0, rect.left), top = Math.max(0, rect.top);
    const right = Math.min(innerWidth, rect.right ?? rect.left + rect.width);
    const bottom = Math.min(innerHeight, rect.bottom ?? rect.top + rect.height);
    return {
      x: left, y: top, width: Math.max(1, right - left), height: Math.max(1, bottom - top),
      viewportWidth: innerWidth, viewportHeight: innerHeight, pixelRatio: devicePixelRatio,
      video: videoState(video)
    };
  }
  function notifyGeometry(session) {
    if (sessions.get(session.requestId) !== session || !session.video) return;
    const next = geometry(session.video);
    const key = JSON.stringify(next);
    if (key === session.geometryKey) return;
    session.geometryKey = key;
    notify(session, 'geometry', { geometry: next });
  }
  async function control(session, command, time) {
    if (sessions.get(session.requestId) !== session) return;
    const video = session.video;
    if (!video || !session.available) return;
    if (command === 'toggle') { if (video.paused) await video.play(); else video.pause(); }
    else if (command === 'mute') video.muted = !video.muted;
    else if (command === 'seek' && Number.isFinite(time) && video.seekable.length) {
      // Snap across gaps to a real seekable range, including live DVR windows.
      let closest = video.seekable.start(0), distance = Infinity;
      for (let i = 0; i < video.seekable.length; i++) {
        const candidate = Math.max(video.seekable.start(i), Math.min(video.seekable.end(i), time));
        if (Math.abs(candidate - time) < distance) { closest = candidate; distance = Math.abs(candidate - time); }
      }
      video.currentTime = closest;
    }
    else if ((command === 'back' || command === 'forward') && video.seekable.length) {
      const start = video.seekable.start(0), end = video.seekable.end(video.seekable.length - 1);
      video.currentTime = Math.max(start, Math.min(end, video.currentTime + (command === 'back' ? -10 : 10)));
    }
    state(session);
  }
  async function resize(session) {
    if (sessions.get(session.requestId) !== session || session.resizing || !session.display || !session.video || !session.sender.track) return;
    session.resizing = true;
    const display = session.display;
    const wasVisible = session.isVisible;
    try {
      const parameters = session.sender.getParameters();
      if (!parameters.encodings?.length) return;
      parameters.degradationPreference = 'maintain-framerate';
      parameters.encodings[0].maxFramerate = 30;
      parameters.encodings[0].active = session.isVisible !== false;
      parameters.encodings[0].maxBitrate = 8000000;
      parameters.encodings[0].scaleResolutionDownBy = Math.max(1, Math.min(
        session.video.videoWidth / display.width, session.video.videoHeight / display.height));
      await session.sender.setParameters(parameters);
    } catch (error) { console.warn('PiP video resolution adjustment failed', error); }
    finally {
      session.resizing = false;
      if (sessions.get(session.requestId) === session && (session.display !== display || session.isVisible !== wasVisible)) scheduleResize(session);
    }
  }
  function scheduleResize(session) {
    clearTimeout(session.resizeTimer);
    session.resizeTimer = setTimeout(() => resize(session), 180);
  }
  function gatherICE(session) {
    return new Promise((resolve, reject) => {
      const peer = session.peer;
      let settle;
      const finish = error => {
        clearTimeout(timer); clearTimeout(settle);
        peer.removeEventListener('icecandidate', candidate);
        peer.removeEventListener('icegatheringstatechange', changed);
        session.cancelICE = undefined;
        error ? reject(error) : resolve();
      };
      const timer = setTimeout(() => finish(new Error('動画の接続準備がタイムアウトしました。')), 8000);
      const candidate = event => {
        if (event.candidate && !settle) settle = setTimeout(() => finish(), 250);
      };
      const changed = () => { if (peer.iceGatheringState === 'complete') finish(); };
      session.cancelICE = () => finish(new Error('動画の接続を終了しました。'));
      peer.addEventListener('icecandidate', candidate);
      peer.addEventListener('icegatheringstatechange', changed);
      changed();
    });
  }

  function availability(session, available, error) {
    const changed = session.available !== available || session.waitReason !== error;
    session.available = available;
    session.waitReason = error;
    if (session.channel?.readyState === 'open')
      session.channel.send(JSON.stringify({ action: 'videoAvailability', available }));
    if (changed) notify(session, 'availability', { available, error });
  }
  function collect(root) {
    const videos = [...root.querySelectorAll('video')];
    for (const element of root.querySelectorAll('*'))
      if (element.shadowRoot) videos.push(...collect(element.shadowRoot));
    return videos;
  }
  function chooseVideo(session) {
    const selected = session.video;
    // A seek can temporarily drop readyState to HAVE_METADATA. Keep ownership
    // of this player instead of dropping its track or selecting a thumbnail.
    if (selected?.isConnected && !selected.error && (!selected.ended || selected.seeking)) return selected;
    const videos = collect(document).filter(video => video.isConnected && !video.ended &&
      video.readyState >= 2 && video.videoWidth > 0 && video.videoHeight > 0);
    // Prefer the explicitly selected player, including when paused. Switching
    // to a playing thumbnail during a main-player reload is not a replacement.
    if (videos.includes(session.video)) return session.video;
    const explicit = videos.find(video => session.sourceURL &&
      (video.currentSrc === session.sourceURL || video.src === session.sourceURL));
    if (explicit) return explicit;
    const playing = videos.filter(video => !video.paused);
    const pool = playing.length ? playing : videos;
    if (pool.includes(session.video)) return session.video;
    const match = pool.find(video => session.sourceURL &&
      (video.currentSrc === session.sourceURL || video.src === session.sourceURL));
    if (match) return match;
    // Prefer the main player to thumbnails/ads when the page has several videos.
    return pool.sort((a, b) => {
      const x = a.getBoundingClientRect(), y = b.getBoundingClientRect();
      return y.width * y.height - x.width * x.height;
    })[0];
  }
  function installFallback(session, video) {
    session.fallback = true;
    session.video = video;
    session.available = true;
    const options = { signal: session.events.signal };
    const changed = () => notifyGeometry(session);
    for (const event of ['play', 'pause', 'volumechange', 'seeked', 'timeupdate', 'durationchange', 'progress', 'resize'])
      video.addEventListener(event, changed, options);
    window.addEventListener('resize', changed, options);
    window.addEventListener('scroll', changed, { capture: true, passive: true, signal: session.events.signal });
    if (typeof ResizeObserver === 'function') {
      session.resizeObserver = new ResizeObserver(changed);
      session.resizeObserver.observe(video);
    }
    session.observer = new MutationObserver(() => scheduleFallbackRefresh(session));
    session.observer.observe(document.documentElement, { childList: true, subtree: true });
    session.healthTimer = setInterval(() => refreshFallback(session), 1500);
    notifyGeometry(session);
  }
  function scheduleFallbackRefresh(session) {
    if (sessions.get(session.requestId) !== session || session.refreshTimer) return;
    session.refreshTimer = setTimeout(() => {
      session.refreshTimer = undefined;
      refreshFallback(session);
    }, 250);
  }
  function refreshFallback(session) {
    if (sessions.get(session.requestId) !== session) return;
    const video = chooseVideo(session);
    if (!video) {
      availability(session, false);
      return;
    }
    if (video !== session.video) {
      clearInterval(session.healthTimer);
      session.events.abort();
      session.events = new AbortController();
      session.resizeObserver?.disconnect();
      session.observer?.disconnect();
      installFallback(session, video);
      return;
    }
    availability(session, true);
    notifyGeometry(session);
  }
  async function refreshVideo(session) {
    if (sessions.get(session.requestId) !== session || session.refreshing) return;
    session.refreshing = true;
    try {
      const previousVideo = session.video;
      if (previousVideo && !previousVideo.isConnected && session.playbackWasActive)
        session.resumeAfterReplacement = true;
      const video = chooseVideo(session);
      const usable = video && !video.mediaKeys && typeof video.captureStream === 'function';
      if (!usable) {
        availability(session, false, video?.mediaKeys ? 'この動画は保護されているため表示できません。' : undefined);
        if (session.sender.track) await session.sender.replaceTrack(null);
        session.videoEvents?.abort();
        session.stream?.getTracks().forEach(track => track.stop());
        session.video = null; session.stream = null;
        return;
      }
      if (video.seeking || video.readyState < 2 || !video.videoWidth || !video.videoHeight) {
        // Buffering is not a missing video. The live sender retains its last
        // frame until playback resumes; do not send an unavailable transition.
        // A real source change still goes through replacement once it is ready.
        state(session);
        return;
      }
      // Sites commonly replace the video element/source between playlist
      // items. Keep playback moving only when the outgoing item had been
      // playing; an intentional user pause must remain paused.
      if (session.resumeAfterReplacement && video.paused && !video.ended) {
        session.resumeAfterReplacement = false;
        try {
          await video.play();
          session.playbackWasActive = true;
        } catch (_) { /* The page may require a fresh user gesture. */ }
      }
      const key = video.currentSrc || video.src;
      if (session.available && video === session.video && key === session.sourceKey && !session.dirty &&
          session.sender.track?.readyState === 'live') {
        state(session);
        return;
      }
      availability(session, false);
      session.videoEvents?.abort();
      let stream;
      try { stream = video.captureStream(); }
      catch (error) {
        // Loading and media-origin restrictions are not a closed browser tab.
        // Keep the peer/PiP slot while waiting for a usable replacement.
        availability(session, false, error?.message);
        if (session.sender.track) await session.sender.replaceTrack(null);
        session.stream?.getTracks().forEach(track => track.stop());
        session.stream = null;
        return;
      }
      stream.getAudioTracks().forEach(track => { track.stop(); stream.removeTrack(track); });
      const track = stream.getVideoTracks()[0];
      if (!track || track.readyState !== 'live') {
        stream.getTracks().forEach(track => track.stop());
        session.dirty = true;
        return;
      }
      track.contentHint = 'motion';
      try { await session.sender.replaceTrack(track); }
      catch (error) { stream.getTracks().forEach(track => track.stop()); throw error; }
      if (sessions.get(session.requestId) !== session) {
        stream.getTracks().forEach(track => track.stop()); return;
      }
      session.stream?.getTracks().forEach(track => track.stop());
      session.stream = stream; session.video = video; session.sourceKey = key;
      session.sourceURL = null; session.dirty = false;
      session.videoEvents = new AbortController();
      const options = { signal: session.videoEvents.signal };
      for (const event of ['emptied', 'ended', 'error', 'encrypted']) {
        video.addEventListener(event, () => {
          if ((event === 'emptied' || event === 'ended') && session.playbackWasActive)
            session.resumeAfterReplacement = true;
          session.dirty = true;
          availability(session, false);
          scheduleRefresh(session);
        }, options);
      }
      track.addEventListener('ended', () => {
        session.dirty = true; availability(session, false);
      }, options);
      for (const event of ['play', 'pause', 'volumechange', 'seeked', 'resize', 'timeupdate', 'durationchange', 'progress'])
        video.addEventListener(event, () => {
          if (event === 'play') session.playbackWasActive = true;
          if (event === 'pause' && !video.ended && !session.dirty) session.playbackWasActive = false;
          state(session);
          if (event === 'resize') scheduleResize(session);
        }, options);
      for (const event of ['loadedmetadata', 'loadeddata', 'canplay', 'seeked', 'playing'])
        video.addEventListener(event, () => {
          if (event === 'playing') {
            session.playbackWasActive = true;
            session.resumeAfterReplacement = false;
          }
          scheduleRefresh(session);
        }, options);
      session.playbackWasActive = !video.paused && !video.ended;
      availability(session, true);
      state(session);
      scheduleResize(session);
    } catch (error) {
      // A replacement outside the negotiated codec envelope needs a fresh peer.
      // The background watchdog restarts this request, preserving its PiP tab.
      fail(session, error);
    } finally { session.refreshing = false; }
  }
  function scheduleRefresh(session) {
    if (sessions.get(session.requestId) !== session || session.refreshTimer) return;
    session.refreshTimer = setTimeout(() => {
      session.refreshTimer = undefined;
      refreshVideo(session);
    }, 100);
  }
  async function start(message) {
    stop(message.requestId);
    const session = { requestId: message.requestId, streamId: crypto.randomUUID(),
      sourceURL: message.sourceURL, events: new AbortController(), available: false,
      display: { width: 1280, height: 720 } };
    sessions.set(session.requestId, session);
    try {
      const video = chooseVideo(session);
      // Chrome deliberately blocks captureStream() for EME-backed players.
      // Keep a lightweight control/geometry bridge and let the background
      // capture the tab, while the native receiver displays only this rect.
      if (video && (video.mediaKeys || typeof video.captureStream !== 'function')) {
        installFallback(session, video);
        return { ok: true, fallback: true, geometry: geometry(video) };
      }
      const peer = session.peer = new RTCPeerConnection({ iceServers: [] });
      session.sender = peer.addTransceiver('video', { direction: 'sendonly' }).sender;
      await refreshVideo(session);
      if (sessions.get(session.requestId) !== session) return { ok: false };
      const channel = session.channel = peer.createDataChannel('viewport');
      channel.onopen = () => { availability(session, session.available, session.waitReason); state(session); };
      channel.onmessage = event => {
        if (sessions.get(session.requestId) !== session) return;
        try {
          const data = JSON.parse(event.data);
          if (data.action === 'presentation' && typeof data.active === 'boolean') {
            session.isVisible = data.active; scheduleResize(session);
          }
          if (data.action === 'ready') notify(session, 'ready');
          if (data.action === 'videoControl') control(session, data.command, data.time).catch(() => {});
          if (data.action === 'displaySize' && Number.isFinite(data.width) && Number.isFinite(data.height)
              && data.width > 0 && data.height > 0) {
            session.display = { width: Math.min(7680, data.width), height: Math.min(7680, data.height) };
            scheduleResize(session);
          }
        } catch (_) {}
      };
      peer.onconnectionstatechange = () => {
        clearTimeout(session.disconnectTimer);
        if (peer.connectionState === 'failed') fail(session, new Error('動画を再接続しています。'));
        if (peer.connectionState === 'disconnected') session.disconnectTimer = setTimeout(
          () => fail(session, new Error('動画を再接続しています。')), 5000);
      };
      session.healthTimer = setInterval(() => refreshVideo(session), 1500);
      session.observer = new MutationObserver(() => scheduleRefresh(session));
      session.observer.observe(document.documentElement, { childList: true, subtree: true });
      // Capture load events for a newly inserted player before its own handlers
      // are attached. Polling remains as a fallback for shadow-root players.
      for (const event of ['loadedmetadata', 'loadeddata', 'canplay'])
        document.addEventListener(event, () => scheduleRefresh(session),
          { capture: true, signal: session.events.signal });
      await peer.setLocalDescription(await peer.createOffer());
      await gatherICE(session);
      if (sessions.get(session.requestId) !== session) return { ok: false };
      await notify(session, 'offer', { sdp: peer.localDescription.sdp,
        width: session.video?.videoWidth || 1280, height: session.video?.videoHeight || 720 });
      return { ok: true };
    } catch (error) {
      fail(session, error);
      return { ok: false, error: error?.message || String(error) };
    }
  }
  chrome.runtime.onMessage.addListener((message, sender, respond) => {
    if (sender.id !== chrome.runtime.id || message?.target !== 'video-element') return;
    if (message.action === 'ping') { respond({ active: sessions.has(message.requestId), available: sessions.get(message.requestId)?.available === true }); return; }
    if (message.action === 'start') { start(message).then(respond); return true; }
    const session = sessions.get(message.requestId);
    if (!session) return;
    if (message.action === 'stop') { stop(message.requestId); respond({ ok: true }); }
    if (message.action === 'control' && session.fallback) {
      control(session, message.command, message.time).then(() => respond({ ok: true }));
      return true;
    }
    if (message.action === 'answer' && message.streamId === session.streamId) {
      session.peer.setRemoteDescription({ type: 'answer', sdp: message.sdp })
        .then(() => respond({ ok: true }))
        .catch(error => { fail(session, error); respond({ ok: false }); });
      return true;
    }
  });
  window.addEventListener('pagehide', () => {
    for (const session of [...sessions.values()]) {
      notify(session, 'waiting'); stop(session.requestId);
    }
  });
})();
