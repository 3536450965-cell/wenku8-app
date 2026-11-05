/*
 * Keeps data/wenku8_index.json current without re-reading the whole table.
 *
 * The site's own search needs an account that can no longer be created, so the
 * app searches a bundled index. New books get the next free id, so a weekly run
 * only has to look past the highest id we already know, plus the handful of
 * holes left by failed fetches.
 *
 *   node tools/index_crawl.mjs [--max-new=400] [--stop-after=150]
 *
 * Exits without touching the file when nothing new was found.
 */
import fs from 'node:fs';
import path from 'node:path';

const FILE = process.env.INDEX_FILE ?? path.resolve('data/wenku8_index.json');
const MAX_NEW = Number(process.env.MAX_NEW ?? 400);
const STOP_AFTER = Number(process.env.STOP_AFTER ?? 150);
const HOSTS = ['https://www.wenku8.cc', 'https://www.wenku8.net'];
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function decode(buf) {
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch {
    return new TextDecoder('gbk').decode(buf);
  }
}

function clean(value) {
  return value
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;?/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/\s+/g, ' ')
    .trim();
}

function pick(html, label) {
  const idx = html.indexOf(label);
  if (idx < 0) return '';
  const cell = html.slice(idx, idx + 500);
  const m = /<td[^>]*>([\s\S]*?)<\/td>/i.exec(cell.slice(label.length));
  return m ? clean(m[1]) : '';
}

function parsePage(html) {
  const titleTag = /<title>([^<]*)<\/title>/i.exec(html)?.[1]?.trim() ?? '';
  if (!titleTag || titleTag.includes('现错误')) return null;
  const parts = titleTag.split(' - ');
  const title = parts[0]?.trim() ?? '';
  if (!title || title.includes('轻小说文库')) return null;
  const length = pick(html, '全文长度').replace(/[^0-9]/g, '');
  const statusText = pick(html, '文章状态');
  return [
    title,
    parts.length > 1 ? parts[1].trim() : '',
    parts.length > 3 ? parts[2].trim() : '',
    statusText.includes('完结') ? '完结' : statusText.includes('连载') ? '连载' : '',
    length ? Number(length) : 0,
  ];
}

const raw = fs.existsSync(FILE) ? JSON.parse(fs.readFileSync(FILE, 'utf8')) : [];
const known = new Map();
for (const row of raw) {
  if (Array.isArray(row) && Number.isInteger(row[0]) && typeof row[1] === 'string') {
    known.set(row[0], row);
  }
}
const maxId = known.size ? Math.max(...known.keys()) : 0;
console.log(`known=${known.size} maxId=${maxId}`);

// Holes below maxId first: cheap, and they occasionally fill in when the site
// restores a book that was down for a while.
const holes = [];
for (let id = 1; id <= maxId; id++) if (!known.has(id)) holes.push(id);

let delay = 1200;
let hostIndex = 0;
let ok = 0;
let miss = 0;
let throttled = 0;

async function fetchBook(id) {
  const host = HOSTS[hostIndex++ % HOSTS.length];
  try {
    const res = await fetch(`${host}/book/${id}.htm`, {
      headers: {
        'user-agent': UA,
        accept: 'text/html,application/xhtml+xml',
        'accept-language': 'zh-CN,zh;q=0.9',
        'accept-encoding': 'gzip, deflate',
        referer: `${host}/`,
      },
      signal: AbortSignal.timeout(25000),
    });
    if (res.status === 429) {
      throttled++;
      delay = Math.min(delay * 2, 20000);
      return { retry: true };
    }
    const html = decode(Buffer.from(await res.arrayBuffer()));
    delay = Math.max(1200, Math.round(delay * 0.92));
    return { status: res.status, html };
  } catch {
    delay = Math.min(delay * 2, 20000);
    return { retry: true };
  }
}

async function grab(id) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const page = await fetchBook(id);
    if (!page.retry) {
      if (page.status !== 200) return null;
      return parsePage(page.html);
    }
    await sleep(delay);
  }
  return null;
}

for (const id of holes) {
  const parsed = await grab(id);
  if (parsed) {
    known.set(id, [id, ...parsed]);
    ok++;
  } else {
    miss++;
  }
  await sleep(delay);
}

// New books: walk past the highest id and stop once the site clearly has no
// more pages (ids are handed out in order, so a long run of misses means done).
let consecutiveMisses = 0;
for (let id = maxId + 1; id <= maxId + MAX_NEW; id++) {
  const parsed = await grab(id);
  if (parsed) {
    known.set(id, [id, ...parsed]);
    ok++;
    consecutiveMisses = 0;
    console.log(`+ ${id} ${parsed[0]}`);
  } else {
    miss++;
    consecutiveMisses++;
    if (consecutiveMisses >= STOP_AFTER) break;
  }
  await sleep(delay);
  if ((ok + miss) % 50 === 0) {
    console.log(`progress ok=${ok} miss=${miss} throttled=${throttled} delay=${delay}`);
  }
}

const rows = [...known.values()].sort((a, b) => a[0] - b[0]);
const next = JSON.stringify(rows);
const before = raw.length ? JSON.stringify(raw) : '';
if (next === before) {
  console.log(`no change (${rows.length} books, ok=${ok} miss=${miss} throttled=${throttled})`);
  process.exit(0);
}
fs.mkdirSync(path.dirname(FILE), { recursive: true });
fs.writeFileSync(FILE, next);
console.log(
  `updated ${raw.length} -> ${rows.length} books (+${rows.length - raw.length}, ` +
    `ok=${ok} miss=${miss} throttled=${throttled})`,
);