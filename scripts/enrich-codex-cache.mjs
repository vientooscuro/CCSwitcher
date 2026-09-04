import fs from 'node:fs';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';

const key = (timestamp, totals) => `${Math.round(timestamp * 1000)}|${totals.join(',')}`;

export async function enrichRequestScopes(lines, aggregate) {
  const byKey = new Map();
  for (const event of aggregate.usageEvents) {
    const id = key(event[0], event[3]);
    if (!byKey.has(id)) byKey.set(id, []);
    byKey.get(id).push(event);
  }
  const matched = new Set();
  let scope = null;
  for await (const line of lines) {
    const head = line.slice(0, 256);
    if (!/"type"\s*:\s*"(?:session_meta|turn_context|event_msg)"/.test(head)) continue;
    if (/"type"\s*:\s*"event_msg"/.test(head) && !/"type"\s*:\s*"token_count"/.test(head)) continue;
    let event;
    try { event = JSON.parse(line); } catch { continue; }
    const payload = event.payload;
    if (event.type === 'session_meta') scope = payload.id ?? payload.session_id ?? null;
    if (event.type === 'turn_context' && payload.turn_id) scope = payload.turn_id;
    const usage = payload?.type === 'token_count' && payload.info?.total_token_usage;
    if (!usage) continue;
    const totals = [usage.input_tokens ?? 0, usage.cached_input_tokens ?? 0, usage.cache_write_input_tokens ?? 0, usage.output_tokens ?? 0];
    const id = key(Date.parse(event.timestamp) / 1000, totals);
    for (const cached of byKey.get(id) ?? []) {
      if (matched.has(cached) && cached[5] !== scope) throw new Error('Ambiguous timestamp bucket spans different turn scopes');
      cached[5] = scope;
      matched.add(cached);
    }
  }
  if (matched.size !== aggregate.usageEvents.length) {
    throw new Error(`Unmatched usage events: ${aggregate.usageEvents.length - matched.size}`);
  }
}

async function main(cachePath) {
  if (!cachePath) throw new Error('Usage: node scripts/enrich-codex-cache.mjs /absolute/cache.json');
  const cache = JSON.parse(fs.readFileSync(cachePath, 'utf8'));
  const sourceVersion = cache.version;
  if (![6, 7].includes(sourceVersion)) throw new Error('Only verified version 6/7 caches can be enriched');
  let enriched = 0, invalidated = 0;
  for (const [path, aggregate] of Object.entries(cache.files)) {
    if (!/\/rollout-[^/]+\.jsonl$/.test(path)) throw new Error('Unexpected cache source path');
    const before = fs.existsSync(path) ? fs.statSync(path).mtimeMs : null;
    if (before === null || Math.abs(before / 1000 - aggregate.mtime) > 0.002) {
      delete cache.files[path]; invalidated++; continue;
    }
    const lines = readline.createInterface({ input: fs.createReadStream(path), crlfDelay: Infinity });
    try {
      await enrichRequestScopes(lines, aggregate);
    } catch {
      lines.close();
      delete cache.files[path]; invalidated++; continue;
    }
    if (fs.statSync(path).mtimeMs !== before) {
      delete cache.files[path]; invalidated++; continue;
    }
    enriched++;
    if (enriched % 250 === 0) console.log(`Enriched ${enriched} rollouts`);
  }
  cache.version = 7;
  const pending = `${cachePath}.v7-building`;
  fs.writeFileSync(pending, JSON.stringify(cache), { flag: 'wx', mode: 0o600 });
  fs.copyFileSync(cachePath, `${cachePath}.v${sourceVersion}-backup`, fs.constants.COPYFILE_EXCL);
  fs.renameSync(pending, cachePath);
  console.log(`Version 7 cache saved: ${enriched} enriched, ${invalidated} changed files will be reparsed`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv[2]).catch(error => { console.error(error.message); process.exitCode = 1; });
}
