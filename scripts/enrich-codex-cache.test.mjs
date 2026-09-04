import { test } from 'node:test';
import assert from 'node:assert/strict';
import { enrichRequestScopes } from './enrich-codex-cache.mjs';

test('binds cached events to stable turn IDs without changing usage', async () => {
  const aggregate = { usageEvents: [[1000, 'day', 'model', [100, 50, 0, 0], [100, 50, 0, 0]]] };
  const lines = [
    JSON.stringify({ type: 'session_meta', payload: { id: 'thread' } }),
    JSON.stringify({ type: 'turn_context', payload: { turn_id: 'turn' } }),
    JSON.stringify({ timestamp: '1970-01-01T00:16:40.000Z', type: 'event_msg', payload: {
      type: 'token_count', info: { total_token_usage: { input_tokens: 100, cached_input_tokens: 50, output_tokens: 0 } }
    } })
  ];
  await enrichRequestScopes(lines, aggregate);
  assert.equal(aggregate.usageEvents[0][5], 'turn');
  assert.deepEqual(aggregate.usageEvents[0][4], [100, 50, 0, 0]);
});

test('refuses to migrate unmatched cached events', async () => {
  await assert.rejects(enrichRequestScopes([], { usageEvents: [[1000, 'day', 'model', [1, 0, 0, 0], [1, 0, 0, 0]]] }));
});

test('rejects timestamp buckets shared by different turn identities', async () => {
  const aggregate = { usageEvents: [[1000, 'day', 'model', [100, 0, 0, 0], [100, 0, 0, 0]]] };
  const usage = JSON.stringify({ timestamp: '1970-01-01T00:16:40.000Z', type: 'event_msg', payload: {
    type: 'token_count', info: { total_token_usage: { input_tokens: 100 } }
  } });
  await assert.rejects(enrichRequestScopes([
    JSON.stringify({ type: 'turn_context', payload: { turn_id: 'one' } }), usage,
    JSON.stringify({ type: 'turn_context', payload: { turn_id: 'two' } }), usage
  ], aggregate));
});
