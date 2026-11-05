const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function harness(options = {}) {
  const messages = [], calls = [], timers = new Map(), listeners = {};
  let timerID = 0;
  const event = name => ({ addListener: fn => { listeners[name] = fn; } });
  const chrome = {
    runtime: {
      id: 'test-extension', getURL: path => `chrome-extension://test-extension/${path}`,
      connectNative: () => ({ postMessage: m => messages.push(m), onMessage: event('native'), onDisconnect: event('disconnect') }),
      getManifest: () => ({ version: '0.6.1' }),
      getContexts: async () => [],
      sendMessage: async m => { calls.push(['message', m]); return { ok: !options.failStart }; },
      onMessage: event('message'), onInstalled: event('installed'), onStartup: event('startup')
    },
    tabs: {
      query: async () => [],
      get: async id => { if (options.missing) throw new Error('No tab'); return { id, title: 'Test', url: 'https://example.com', active: false }; },
      update: () => { throw new Error('Unexpected activation'); },
      ...Object.fromEntries(['onCreated','onRemoved','onUpdated','onMoved','onActivated'].map(n => [n, event(n)]))
    },
    windows: { onRemoved: event('windowRemoved'), update: () => { throw new Error('Unexpected focus'); } },
    contextMenus: { onClicked: event('menu') },
    scripting: { executeScript: async spec => {
      calls.push(['viewport', spec.target]);
      return [{ result: { width: 1512, height: 805 } }];
    } },
    offscreen: { createDocument: async spec => calls.push(['create', spec]) },
    tabCapture: { getMediaStreamId: async target => {
      calls.push(['stream', target]);
      if (options.denied) throw new Error('not invoked');
      return 'selected-tab-stream';
    } }
  };
  Object.defineProperty(chrome, 'debugger', { get() { throw new Error('Unexpected debugger access'); } });
  const context = vm.createContext({ chrome, console, crypto: { randomUUID: () => 'popup' },
    setInterval: () => 0, clearInterval: () => {},
    setTimeout: (fn, delay) => { timers.set(++timerID, {fn,delay}); return timerID; },
    clearTimeout: id => timers.delete(id)
  });
  vm.runInContext(fs.readFileSync(require.resolve('../ChromeExtension/background.js'), 'utf8'), context);
  return { messages, calls, timers, listeners,
    run: code => vm.runInContext(code, context),
    frame: (tabId, requestId, url = 'offscreen.html') => listeners.message(
      { target: 'background', action: 'frame', tabId, requestId, data: 'aW1hZ2U=' },
      { id: chrome.runtime.id, url: chrome.runtime.getURL(url) }, () => {}
    ),
    fire: async delay => { const [id,timer] = [...timers].find(([,t]) => t.delay === delay); timers.delete(id); await timer.fn(); }
  };
}

test('manifest has tab-only capture and no debugger or display permissions', () => {
  const manifest = require('../ChromeExtension/manifest.json');
  assert.ok(manifest.permissions.includes('tabCapture'));
  assert.ok(manifest.permissions.includes('offscreen'));
  for (const permission of ['debugger', 'desktopCapture', '<all_urls>']) {
    assert.equal(manifest.permissions.includes(permission), false);
  }
});

test('only explicit selected tab is requested, without activation or premature success', async () => {
  const h = harness();
  await h.run("captureTab(42, 'first')");
  assert.deepEqual(JSON.parse(JSON.stringify(h.calls.find(([m]) => m === 'stream')[1])), { targetTabId: 42 });
  assert.equal(h.calls.filter(([m]) => m === 'stream').length, 1);
  assert.equal(h.calls.find(([m]) => m === 'viewport')[1].tabId, 42);
  assert.equal(h.messages.some(m => m.action === 'captureTabStarted'), false);
  h.frame(42, 'first');
  const actions = h.messages.filter(m => ['tabFrame','captureTabStarted'].includes(m.action));
  assert.deepEqual(actions.map(m => m.action), ['tabFrame','captureTabStarted']);
  assert.equal(actions[0].requestId, 'first');
});

test('missing tabs report errors instead of rejecting outside the handler', async () => {
  const h = harness({ missing: true });
  await h.run("captureTab(1, 'missing')");
  assert.equal(h.messages.find(m => m.action === 'captureTabError').error, 'No tab');
});

test('missing activeTab grant gives actionable error, with no fallback or activation', async () => {
  const h = harness({ denied: true });
  await h.run("captureTab(1, 'denied')");
  assert.match(h.messages.find(m => m.action === 'captureTabError').error, /対象タブで拡張機能のアイコンを1回/);
  assert.equal(h.calls.filter(([m]) => m === 'stream').length, 1);
  assert.equal(h.calls.some(([m, v]) => m === 'message' && v.action === 'start'), false);
  assert.equal(h.run('captureSession'), undefined);
});

test('setup failure stops the offscreen receiver', async () => {
  const h = harness({ failStart: true });
  await h.run("captureTab(1, 'fail')");
  assert.equal(h.calls.filter(([m, v]) => m === 'message' && v.action === 'stop').length, 1);
  assert.equal(h.run('captureSession'), undefined);
});

test('old capture stops before new capture, and stale close cannot stop replacement', async () => {
  const h = harness();
  await h.run("captureTab(1, 'old')");
  await h.run("captureTab(1, 'new')");
  const events = h.calls.filter(([m, v]) => m === 'stream' || (m === 'message' && ['start', 'stop'].includes(v.action)));
  assert.deepEqual(events.map(([m, v]) => m === 'stream' ? 'stream' : v.action), ['stream', 'start', 'stop', 'stream', 'start']);
  await h.run("stopTabCapture(1, 'old')");
  assert.equal(h.run('captureSession.requestId'), 'new');
});

test('late, wrong-tab, and untrusted-source frames are ignored', async () => {
  const h = harness();
  await h.run("captureTab(2, 'new')");
  h.frame(1, 'old');
  h.frame(1, 'new');
  h.frame(2, 'new', 'popup.html');
  assert.equal(h.messages.some(m => m.action === 'tabFrame'), false);
  h.frame(2, 'new');
  assert.equal(h.messages.filter(m => m.action === 'tabFrame').length, 1);
});

test('no-frame timeout reports failure and releases capture', async () => {
  const h = harness();
  await h.run("captureTab(1, 'empty')");
  await h.fire(10000);
  await h.run('commandQueue');
  assert.equal(h.messages.some(m => m.action === 'captureTabError'), true);
  assert.equal(h.run('captureSession'), undefined);
});

test('native disconnection stops capture', async () => {
  const h = harness();
  await h.run("captureTab(1, 'disconnect')");
  h.listeners.disconnect();
  await h.run('commandQueue');
  assert.equal(h.run('captureSession'), undefined);
});
