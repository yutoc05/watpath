#!/usr/bin/env node
// Renders a page from tools/demo to PNGs with headless Chrome, talking to it over the
// DevTools protocol so fonts load once and each frame is taken at an exact time.
//
//   node render.mjs <url> <out.png> [--size 1920x1080] [--transparent]
//   node render.mjs <url> <dir> --frames 60      one PNG per frame of the page's animation
//
// A page that animates sets window.duration and window.seek(seconds); one that loads
// fonts sets window.ready to a promise.
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const CHROME = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

const [url, out, ...rest] = process.argv.slice(2);
if (!url || !out) {
  console.error('usage: render.mjs <url> <out> [--size WxH] [--transparent] [--frames fps]');
  process.exit(2);
}
const option = name => {
  const index = rest.indexOf(name);
  return index === -1 ? undefined : rest[index + 1];
};
const [width, height] = (option('--size') ?? '1920x1080').split('x').map(Number);
const transparent = rest.includes('--transparent');
const fps = option('--frames') ? Number(option('--frames')) : undefined;

const profile = mkdtempSync(join(tmpdir(), 'watpath-render-'));
const chrome = spawn(CHROME, [
  '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
  '--hide-scrollbars', '--force-color-profile=srgb', '--no-first-run', 'about:blank',
], { stdio: ['ignore', 'ignore', 'pipe'] });

const endpoint = await new Promise((resolve, reject) => {
  let log = '';
  chrome.stderr.on('data', chunk => {
    log += chunk;
    const match = log.match(/DevTools listening on (ws:\/\/\S+)/);
    if (match) resolve(match[1]);
  });
  chrome.on('exit', () => reject(new Error(`Chrome quit before it was ready:\n${log}`)));
});

const socket = new WebSocket(endpoint);
await new Promise(resolve => socket.addEventListener('open', resolve, { once: true }));
let nextId = 1;
const pending = new Map();
const waiters = [];
socket.addEventListener('message', ({ data }) => {
  const message = JSON.parse(data);
  if (message.id && pending.has(message.id)) {
    const { resolve, reject } = pending.get(message.id);
    pending.delete(message.id);
    message.error ? reject(new Error(message.error.message)) : resolve(message.result);
  } else if (message.method) {
    for (const waiter of waiters.filter(w => w.method === message.method)) {
      waiters.splice(waiters.indexOf(waiter), 1);
      waiter.resolve(message.params);
    }
  }
});
const send = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
  const id = nextId++;
  pending.set(id, { resolve, reject });
  socket.send(JSON.stringify({ id, method, params, sessionId }));
});
const once = method => new Promise(resolve => waiters.push({ method, resolve }));

try {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const page = (method, params) => send(method, params, sessionId);
  await page('Page.enable');
  await page('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false });
  if (transparent) {
    await page('Emulation.setDefaultBackgroundColorOverride', { color: { r: 0, g: 0, b: 0, a: 0 } });
  }
  const loaded = once('Page.loadEventFired');
  await page('Page.navigate', { url });
  await loaded;
  const evaluate = async expression => {
    const { result, exceptionDetails } = await page('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
    return result.value;
  };
  await evaluate('Promise.resolve(window.ready ?? document.fonts.ready).then(() => true)');
  const capture = async path => {
    const { data } = await page('Page.captureScreenshot', { format: 'png' });
    writeFileSync(path, Buffer.from(data, 'base64'));
  };
  if (fps) {
    const duration = await evaluate('window.duration');
    const count = Math.round(duration * fps) + 1;
    mkdirSync(out, { recursive: true });
    for (let frame = 0; frame < count; frame++) {
      await evaluate(`window.seek(${frame / fps})`);
      await capture(join(out, `frame-${String(frame).padStart(4, '0')}.png`));
    }
    console.log(`${count} frames in ${out}`);
  } else {
    await capture(out);
    console.log(out);
  }
} finally {
  socket.close();
  await new Promise(resolve => {
    chrome.once('exit', resolve);
    chrome.kill();
  });
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
