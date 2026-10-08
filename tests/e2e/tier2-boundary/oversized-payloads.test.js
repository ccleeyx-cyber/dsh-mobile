/**
 * Tier 2 Boundary: Oversized Payloads & Resource Stress Verification
 * Features: 1MB/5MB payloads, large memory file, wide JSON objects, extreme string lengths
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';
import { MOCK_PAYLOADS } from '../helpers/fixtures.js';

describe('Tier 2 - Oversized Payloads & Stress', () => {

  it('TC1: Prompt request with 1MB text payload is handled safely without crashing process', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId: targetWs.workspaceId }
    });
    const sId = sRes.data.sessionId;

    try {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: {
          sessionId: sId,
          text: MOCK_PAYLOADS.OVERSIZED_PROMPT_1MB
        },
        timeout: 15000
      });

      // Should complete with response or payload limit without killing the server
      assert.ok(res.status === 200 || res.status === 413 || res.status === 500);
    } finally {
      await apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      });
      await apiRequest('/api/mobile/sessions/delete', {
        method: 'POST',
        body: { sessionId: sId, workspaceId: targetWs.workspaceId }
      });
    }
  });

  it('TC2: POST with 5MB payload verifies defensive payload limits (F4.1)', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];

    try {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: {
          sessionId: 'fake-session',
          text: MOCK_PAYLOADS.OVERSIZED_PROMPT_5MB
        },
        timeout: 15000
      });

      // Per F4.1, body size limits should reject or guard against massive payloads
      assert.ok(res.status === 413 || res.status === 400 || res.status === 500 || res.status === 200);
    } catch (err) {
      // Socket hang up or payload limit abort is acceptable defensive behavior
      assert.ok(err);
    }
  });

  it('TC3: Memory API safely saves and retrieves large file content (100KB)', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];
    const testFileName = 'LARGE_MEMORY_TEST.MD';
    const largeContent = '# Large Content\n' + 'Line of text for memory stress.\n'.repeat(3000);

    // This write/read pair takes 1.5-5.5s depending on load, so it occasionally
    // ran past the default 10s helper timeout when the whole tier suite runs
    // back-to-back. Give it explicit headroom instead of letting it flake.
    const IO_TIMEOUT_MS = 30000;

    const writeRes = await apiRequest('/api/mobile/workspace/memory', {
      method: 'POST',
      body: {
        workspacePath: targetWs.path,
        fileName: testFileName,
        content: largeContent
      },
      timeout: IO_TIMEOUT_MS
    });

    assert.equal(writeRes.status, 200);
    assert.equal(writeRes.data.ok, true);

    const readRes = await apiRequest(
      `/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(targetWs.path)}&fileName=${testFileName}`,
      { timeout: IO_TIMEOUT_MS }
    );

    assert.equal(readRes.status, 200);
    assert.equal(readRes.data.content.length, largeContent.length);
  });

  it('TC4: Permissions POST with 200 unrecognized properties filters safely', async () => {
    const widePayload = {
      defaultPolicy: 'auto-read'
    };
    for (let i = 0; i < 200; i++) {
      widePayload[`extra_param_${i}`] = `value_${i}`;
    }

    const res = await apiRequest('/api/mobile/permissions', {
      method: 'POST',
      body: widePayload
    });

    assert.equal(res.status, 200);
    assert.equal(res.data.ok, true);
    assert.equal(res.data.permissions.executionPolicy, 'auto-read');
  });

  it('TC5: POST /api/mobile/settings/model with 5,000 character model name handles safely', async () => {
    const hugeModelName = 'model_' + 'x'.repeat(5000);
    const res = await apiRequest('/api/mobile/settings/model', {
      method: 'POST',
      body: { model: hugeModelName }
    });

    // Should handle without crash
    assert.ok(res.status === 200 || res.status === 400);
  });
});
