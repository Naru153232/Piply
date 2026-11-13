const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const preview = fs.readFileSync(
  require.resolve('../Piply/CapturePreviewView.swift'),
  'utf8'
);

test('native PiP fits the full capture without exposing pixels outside an intentional crop', () => {
  assert.match(preview, /private let cropLayer = CALayer\(\)/);
  assert.match(preview, /cropLayer\.masksToBounds = true/);
  assert.match(preview, /cropLayer\.addSublayer\(displayLayer\)/);
  assert.match(preview, /let scale = min\(bounds\.width \/ crop\.width, bounds\.height \/ crop\.height\)/);
  assert.doesNotMatch(preview, /let scale = max\(bounds\.width \/ crop\.width, bounds\.height \/ crop\.height\)/);
});

test('Chrome PiP fits the complete viewport instead of cropping it to fill', () => {
  assert.match(preview, /const scale = Math\.min\(innerWidth \/ w, innerHeight \/ h\)/);
  assert.doesNotMatch(preview, /const scale = Math\.max\(innerWidth \/ w, innerHeight \/ h\)/);
});
