const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

async function runPopup(url) {
  const messages = [], elements = {};
  const element = () => ({ hidden: false, children: [], addEventListener() {}, appendChild(child) { this.children.push(child); } });
  for (const id of ['#tabs', '#status', '#browser-pip']) elements[id] = element();
  vm.runInNewContext(fs.readFileSync(require.resolve('../ChromeExtension/popup.js'), 'utf8'), {
    document: { querySelector: id => elements[id], createElement: element },
    chrome: {
      tabs: { query: async () => [{ id: 77, title: 'Test', url }] },
      runtime: { onMessage: { addListener() {} }, sendMessage: async m => { messages.push(m); return { ok: true }; } }
    },
    crypto: { randomUUID: () => 'auto-start' }, URL, setTimeout() {}, window: { close() {} }
  });
  await new Promise(resolve => setImmediate(resolve));
  return { messages, elements };
}

test('opening extension starts tab-only PiP without a second button click', async () => {
  const h = await runPopup('https://example.com');
  assert.equal(h.messages.length, 1);
  assert.equal(h.messages[0].action, 'captureTab');
  assert.equal(h.messages[0].tabId, 77);
  assert.equal(h.elements['#tabs'].children[1].hidden, true);
});

test('protected video page does not silently start screen capture', async () => {
  const h = await runPopup('https://www.netflix.com/watch/test');
  assert.equal(h.messages.length, 0);
});
