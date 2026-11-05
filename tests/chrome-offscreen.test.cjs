const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function harness({ deferred = false, failPlay = false } = {}) {
  const messages = [], constraints = [], tracks = [], videos = [], canvases = [], timers = new Map(), pending = [];
  let timerID = 0;
  const createStream = () => {
    const track = { stopped: false, readyState: 'live', listeners: {},
      stop() { this.stopped = true; this.readyState = 'ended'; },
      addEventListener(name, fn) { this.listeners[name] = fn; }
    };
    tracks.push(track);
    return { getTracks: () => [track], getVideoTracks: () => [track] };
  };
  const context = vm.createContext({
    chrome: { runtime: { id: 'test', sendMessage: async m => messages.push(m), onMessage: { addListener() {} } } },
    window: { addEventListener() {} },
    navigator: { mediaDevices: { getUserMedia: spec => {
      constraints.push(spec);
      if (deferred) return new Promise(resolve => pending.push(() => resolve(createStream())));
      return Promise.resolve(createStream());
    } } },
    document: { createElement: name => {
      if (name === 'video') {
        const video = { readyState: 2, videoWidth: 1280, videoHeight: 720,
          play: async () => { if (failPlay) throw new Error('play failed'); }, pause() {} };
        videos.push(video);
        return video;
      }
      const canvas = { width: 0, height: 0, getContext: () => ({ drawImage() {} }), toDataURL: () => 'data:image/jpeg;base64,aW1hZ2U=' };
      canvases.push(canvas);
      return canvas;
    } },
    setTimeout: fn => { timers.set(++timerID, fn); return timerID; },
    clearTimeout: id => timers.delete(id)
  });
  vm.runInContext(fs.readFileSync(require.resolve('../ChromeExtension/offscreen.js'), 'utf8'), context);
  return { messages, constraints, tracks, videos, canvases, timers, pending,
    run: code => vm.runInContext(code, context)
  };
}

test('receiver asks for video only from supplied tab stream, never screen or audio', async () => {
  const h = harness();
  await h.run("start({ tabId: 7, requestId: 'one', streamId: 'tab-seven' })");
  assert.deepEqual(JSON.parse(JSON.stringify(h.constraints[0])), {
    audio: false, video: { mandatory: {
      chromeMediaSource: 'tab', chromeMediaSourceId: 'tab-seven',
      minWidth: 1, minHeight: 1, maxWidth: 1920, maxHeight: 1080, maxFrameRate: 15
    } }
  });
  assert.equal(h.messages[0].action, 'frame');
  assert.equal(h.messages[0].tabId, 7);
  assert.equal(h.messages[0].requestId, 'one');
  h.run("stop('one')");
  assert.ok(h.tracks[0].stopped);
  assert.equal(h.videos[0].srcObject, null);
  assert.equal(h.timers.size, 0);
});

test('replacing capture stops old tracks and stale stop leaves replacement intact', async () => {
  const h = harness();
  await h.run("start({ tabId: 1, requestId: 'old', streamId: 'old' })");
  await h.run("start({ tabId: 2, requestId: 'new', streamId: 'new' })");
  h.run("stop('old')");
  assert.ok(h.tracks[0].stopped);
  assert.equal(h.tracks[1].stopped, false);
});

test('late media acquisition after stop is immediately released without frames', async () => {
  const h = harness({ deferred: true });
  const starting = h.run("start({ tabId: 1, requestId: 'late', streamId: 'late' })");
  h.run("stop('late')");
  h.pending.shift()();
  await starting;
  assert.ok(h.tracks[0].stopped);
  assert.equal(h.messages.length, 0);
});

test('play failure releases tracks and reports error', async () => {
  const h = harness({ failPlay: true });
  await h.run("start({ tabId: 1, requestId: 'fail', streamId: 'fail' })");
  assert.ok(h.tracks[0].stopped);
  assert.equal(h.messages[0].action, 'error');
});

test('browser stop reports termination and stops frame loop', async () => {
  const h = harness();
  await h.run("start({ tabId: 1, requestId: 'end', streamId: 'end' })");
  h.tracks[0].listeners.ended();
  assert.equal(h.messages.at(-1).action, 'error');
  assert.equal(h.run('currentSession'), undefined);
  assert.equal(h.timers.size, 0);
});

test('canvas follows changing source size without a fixed-aspect letterbox', async () => {
  const h = harness();
  await h.run("start({ tabId: 1, requestId: 'resize', streamId: 'resize' })");
  assert.equal(h.canvases[0].width, 1280);
  assert.equal(h.canvases[0].height, 720);
  h.videos[0].videoWidth = 600;
  h.videos[0].videoHeight = 1200;
  await h.run('pumpFrame(currentSession)');
  assert.equal(h.canvases[0].width, 540);
  assert.equal(h.canvases[0].height, 1080);
  h.videos[0].videoWidth = 2400;
  h.videos[0].videoHeight = 600;
  await h.run('pumpFrame(currentSession)');
  assert.equal(h.canvases[0].width, 1920);
  assert.equal(h.canvases[0].height, 480);
});

test('Chrome-added letterbox is removed using tab geometry, not pixel colors', () => {
  const h = harness();
  const rect = h.run('contentRect(1920, 1080, { width: 1512, height: 805 })');
  assert.equal(rect.width, 1920);
  assert.ok(rect.y > 28 && rect.y < 30);
  assert.ok(Math.abs(rect.height / rect.width - 805 / 1512) < 0.00001);
  const portrait = h.run('contentRect(1920, 1080, { width: 400, height: 800 })');
  assert.equal(portrait.width, 540);
  assert.equal(portrait.height, 1080);
  assert.equal(portrait.x, 690);
  const same = h.run('contentRect(1920, 1080, { width: 1600, height: 900 })');
  assert.equal(same.x, 0);
  assert.equal(same.y, 0);
});
