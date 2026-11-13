const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function video(source, paused, { protectedVideo = false } = {}) {
  const listeners = {};
  const track = {
    readyState: 'live', stopped: false, listeners: {},
    stop() { this.stopped = true; this.readyState = 'ended'; },
    addEventListener(name, callback) { this.listeners[name] = callback; }
  };
  return {
    currentSrc: source, src: source, paused, ended: false, seeking: false,
    isConnected: true, error: null, readyState: 4,
    videoWidth: 1280, videoHeight: 720, muted: false, currentTime: 0,
    duration: 60, seekable: { length: 1, start: () => 0, end: () => 60 },
    mediaKeys: protectedVideo ? {} : null,
    playCalls: 0, track, listeners,
    async play() { this.playCalls++; this.paused = false; },
    captureStream() { return { getTracks: () => [track], getVideoTracks: () => [track], getAudioTracks: () => [], removeTrack() {} }; },
    addEventListener(name, callback) { (listeners[name] ||= []).push(callback); },
    getBoundingClientRect() { return { left: 40, top: 20, right: 1320, bottom: 740, width: 1280, height: 720 }; },
    fire(name) { for (const callback of listeners[name] || []) callback(); }
  };
}

function harness(initialVideo) {
  let videos = [initialVideo];
  const intervals = [], listeners = {};
  const sender = {
    track: null,
    async replaceTrack(track) { this.track = track; },
    getParameters() { return { encodings: [{}] }; },
    async setParameters() {}
  };
  class Peer {
    constructor() { this.connectionState = 'connected'; this.iceGatheringState = 'complete'; }
    addTransceiver() { return { sender }; }
    createDataChannel() { return { readyState: 'connecting', send() {} }; }
    async createOffer() { return { type: 'offer', sdp: 'offer' }; }
    async setLocalDescription(description) { this.localDescription = description; }
    addEventListener() {}
    removeEventListener() {}
    close() {}
  }
  const root = {
    querySelectorAll(selector) { return selector === 'video' ? videos : []; }
  };
  const context = vm.createContext({
    chrome: { runtime: {
      id: 'test', sendMessage: async () => ({}),
      onMessage: { addListener(callback) { listeners.message = callback; } }
    } },
    document: { ...root, documentElement: root, addEventListener() {} },
    window: { addEventListener() {} }, innerWidth: 1440, innerHeight: 900, devicePixelRatio: 2,
    RTCPeerConnection: Peer,
    MutationObserver: class { observe() {} disconnect() {} },
    ResizeObserver: class { observe() {} disconnect() {} },
    AbortController, console,
    crypto: { randomUUID: () => 'stream' },
    setInterval(callback) { intervals.push(callback); return intervals.length; },
    clearInterval() {}, setTimeout, clearTimeout
  });
  vm.runInContext(fs.readFileSync(require.resolve('../ChromeExtension/video-element.js'), 'utf8'), context);
  return {
    async start() {
      return new Promise(resolve => listeners.message(
        { target: 'video-element', action: 'start', requestId: 'request' },
        { id: 'test' }, resolve));
    },
    replace(nextVideo) { initialVideo.isConnected = false; videos = [nextVideo]; },
    async refresh() { await intervals[0](); }
  };
}

test('a playing playlist item resumes its paused replacement', async () => {
  const first = video('first.mp4', false);
  const next = video('next.mp4', true);
  const h = harness(first);
  await h.start();

  first.ended = true;
  first.paused = true;
  first.fire('ended');
  h.replace(next);
  await h.refresh();

  assert.equal(next.playCalls, 1);
  assert.equal(next.paused, false);
});

test('a replacement stays paused when the previous item was paused by the user', async () => {
  const first = video('first.mp4', true);
  const next = video('next.mp4', true);
  const h = harness(first);
  await h.start();

  first.fire('pause');
  h.replace(next);
  await h.refresh();

  assert.equal(next.playCalls, 0);
  assert.equal(next.paused, true);
});

test('an EME-backed YouTube-style video falls back to tab crop geometry', async () => {
  const protectedVideo = video('blob:https://www.youtube.com/video', false, { protectedVideo: true });
  const h = harness(protectedVideo);
  const result = await h.start();

  assert.equal(result.ok, true);
  assert.equal(result.fallback, true);
  assert.deepEqual(JSON.parse(JSON.stringify(result.geometry)), {
    x: 40, y: 20, width: 1280, height: 720,
    viewportWidth: 1440, viewportHeight: 900, pixelRatio: 2,
    video: { paused: false, muted: false, currentTime: 0, duration: 60, seekStart: 0, seekEnd: 60 }
  });
});
