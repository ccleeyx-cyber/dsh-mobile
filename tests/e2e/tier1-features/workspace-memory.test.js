/**
 * Tier 1: Workspace Memory & Audit Trail Verification
 * Features: Query MEMORY.md, update MEMORY.md, validate audit logs, reject missing params
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 1 - Workspace Memory & Audit Trail', () => {

  it('TC1: GET /api/mobile/workspace/memory with missing workspacePath returns HTTP 400', async () => {
    const res = await apiRequest('/api/mobile/workspace/memory');
    assert.equal(res.status, 400);
    assert.ok(res.data.error, 'Should return missing workspacePath error');
  });

  it('TC2: GET /api/mobile/workspace/memory with valid workspace returns file status and content', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];

    const res = await apiRequest(
      `/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(targetWs.path)}&fileName=USER.MD`
    );

    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.code, 0);
    assert.equal(res.data.fileName, 'USER.MD');
    assert.equal(typeof res.data.content, 'string');
    assert.equal(typeof res.data.exists, 'boolean');
  });

  it('TC3: POST /api/mobile/workspace/memory with missing parameters returns HTTP 400', async () => {
    const res = await apiRequest('/api/mobile/workspace/memory', {
      method: 'POST',
      body: { content: 'Some guidelines' }
    });
    assert.equal(res.status, 400);
    assert.ok(res.data.error);
  });

  it('TC4: POST /api/mobile/workspace/memory writes test guidelines and verifies content', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const testFileName = 'E2E_MEMORY_TEST.MD';
    const testContent = `# E2E Test Guidelines\nTimestamp: ${Date.now()}\n`;

    // Observed 1.7-5.2s under load; the default 10s helper timeout left little
    // headroom when the tier runs back-to-back with the rest of the suite.
    const IO_TIMEOUT_MS = 30000;

    const writeRes = await apiRequest('/api/mobile/workspace/memory', {
      method: 'POST',
      body: {
        workspacePath: targetWs.path,
        fileName: testFileName,
        content: testContent
      },
      timeout: IO_TIMEOUT_MS
    });

    assert.equal(writeRes.status, 200);
    assert.equal(writeRes.data.ok, true);

    // Read back
    const readRes = await apiRequest(
      `/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(targetWs.path)}&fileName=${testFileName}`,
      { timeout: IO_TIMEOUT_MS }
    );

    assert.equal(readRes.status, 200);
    assert.equal(readRes.data.content, testContent);
    assert.equal(readRes.data.exists, true);
  });

  it('TC5: GET /api/mobile/audit-logs returns audit log entries', async () => {
    const res = await apiRequest('/api/mobile/audit-logs');
    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    // Accommodate both logs and auditLogs schema variants
    const logs = res.data.logs || res.data.auditLogs;
    assert.ok(Array.isArray(logs), 'Audit logs should be an array');
  });

  it('TC6: GET /api/mobile/workspace/memory without token returns HTTP 401', async () => {
    const res = await apiRequest('/api/mobile/workspace/memory', { token: null });
    assert.equal(res.status, 401);
  });
});
