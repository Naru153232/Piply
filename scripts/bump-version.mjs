#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const rootDirectory = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const versionFile = path.join(rootDirectory, 'VERSION');
const currentVersion = fs.readFileSync(versionFile, 'utf8').trim();
const versionPattern = /^(\d+)\.(\d+)\.(\d+)$/;
const currentMatch = currentVersion.match(versionPattern);

if (!currentMatch) {
  throw new Error(`VERSIONに有効なSemVerが設定されていません: ${currentVersion}`);
}

const requestedChange = process.argv[2] ?? 'patch';
const [, currentMajor, currentMinor, currentPatch] = currentMatch.map(Number);

const nextVersion = (() => {
  switch (requestedChange) {
    case 'major': return `${currentMajor + 1}.0.0`;
    case 'minor': return `${currentMajor}.${currentMinor + 1}.0`;
    case 'patch': return `${currentMajor}.${currentMinor}.${currentPatch + 1}`;
    default: {
      const explicitVersion = requestedChange.replace(/^v/, '');
      if (!versionPattern.test(explicitVersion)) {
        throw new Error('使い方: node scripts/bump-version.mjs [patch|minor|major|x.y.z]');
      }
      return explicitVersion;
    }
  }
})();

if (nextVersion === currentVersion) {
  throw new Error(`新しいバージョンは現在のバージョンと同じです: ${currentVersion}`);
}

const replacements = [
  {
    file: 'project.yml',
    from: `MARKETING_VERSION: "${currentVersion}"`,
    to: `MARKETING_VERSION: "${nextVersion}"`,
    expectedCount: 1
  },
  {
    file: 'Piply.xcodeproj/project.pbxproj',
    from: `MARKETING_VERSION = ${currentVersion};`,
    to: `MARKETING_VERSION = ${nextVersion};`,
    expectedCount: 2
  },
  {
    file: 'ChromeExtension/manifest.json',
    from: `"version": "${currentVersion}"`,
    to: `"version": "${nextVersion}"`,
    expectedCount: 1
  }
];

const updates = replacements.map(replacement => {
  const filePath = path.join(rootDirectory, replacement.file);
  const source = fs.readFileSync(filePath, 'utf8');
  const actualCount = source.split(replacement.from).length - 1;
  if (actualCount !== replacement.expectedCount) {
    throw new Error(`${replacement.file}のバージョンがVERSIONと一致しません（期待: ${replacement.expectedCount}箇所、実際: ${actualCount}箇所）`);
  }
  return { filePath, content: source.replaceAll(replacement.from, replacement.to) };
});

for (const update of updates) {
  fs.writeFileSync(update.filePath, update.content);
}
fs.writeFileSync(versionFile, `${nextVersion}\n`);

console.log(`Piply: ${currentVersion} → ${nextVersion}`);
console.log('アプリとChrome拡張機能のバージョンを更新しました。');
