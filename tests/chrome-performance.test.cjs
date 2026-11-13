const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const read = path => fs.readFileSync(require.resolve(`../${path}`), 'utf8');

test('Chrome capture is capped for a PiP-sized destination', () => {
  const offscreen = read('ChromeExtension/offscreen.js');
  assert.match(offscreen, /maxWidth: 1920, maxHeight: 1080, maxFrameRate: 30/);
  assert.match(offscreen, /maxBitrate = 8000000/);
  assert.doesNotMatch(offscreen, /maxBitrate = 40000000/);
  assert.doesNotMatch(offscreen, /maxFrameRate: 60/);
});

test('viewport checks no longer inject script four times per second', () => {
  const background = read('ChromeExtension/background.js');
  assert.match(background, /setTimeout\(\(\) => updateViewport\(session\), 1500\)/);
  assert.doesNotMatch(background, /updateViewport\(session\), 250\)/);
});

test('native window capture caps Retina sources and queue depth', () => {
  const stream = read('Piply/ScreenStreamSession.swift');
  assert.match(stream, /min\(1, 1920 \/ sourceWidth, 1080 \/ sourceHeight\)/);
  assert.match(stream, /configuration\.queueDepth = 3/);
});

test('native receiver crops a tab stream to the selected video rectangle', () => {
  const preview = read('Piply/CapturePreviewView.swift');
  assert.match(preview, /viewport\?\.sourceWidth/);
  assert.match(preview, /viewport\?\.crop/);
  assert.match(preview, /crop\.x \* sourceScale/);
});
