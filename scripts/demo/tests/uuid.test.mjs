import { test } from 'node:test';
import assert from 'node:assert/strict';
import { uuidv5, NS_DNS, NS_ARLET, idFor, workspaceId } from '../lib/uuid.mjs';

test('uuidv5 matches the published DNS vector', () => {
  assert.equal(uuidv5('www.example.com', NS_DNS), '2ed6657d-e927-568b-95e1-2665a8aea6a2');
});

test('uuidv5 sets version 5 and the RFC variant', () => {
  const id = uuidv5('anything', NS_DNS);
  assert.match(id, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test('idFor is stable per table and key, and distinct across tables', () => {
  assert.equal(idFor('companies', 1), idFor('companies', 1));
  assert.notEqual(idFor('companies', 1), idFor('contacts', 1));
});

test('workspaceId is uuidv5 of arlet:<uid8>:<workspace> in the Arlet namespace', () => {
  assert.equal(workspaceId('0a1b2c3d', 'operations'), uuidv5('arlet:0a1b2c3d:operations', NS_ARLET));
  assert.notEqual(workspaceId('0a1b2c3d', 'operations'), workspaceId('0a1b2c3d', 'finance'));
  assert.notEqual(workspaceId('0a1b2c3d', 'finance'), workspaceId('ffffffff', 'finance'));
  assert.throws(() => workspaceId('0a1b2c3d', 'sales'));
  assert.throws(() => workspaceId('XYZ', 'finance'));
});
