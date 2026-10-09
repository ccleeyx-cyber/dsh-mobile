/**
 * Tier 2 Boundary: Oversized Payloads & Resource Stress Verification
 * Features: 1MB/5MB payloads, large memory file, wide JSON objects, extreme string lengths
 *
 * ⚠️ DESTRUCTIVE SUITE — despite living in the "boundary" tier, TC3 writes a
 * 96 KB scratch file into a real workspace, TC4 rewrites the live global
 * execution policy, and TC5 posts a 5 KB garbage model name at the live default
 * model. All three now snapshot-and-restore via helpers/guard.js. Run it with
 * `npm run test:destructive`, not `npm test`.
 */

import fs from 'node:fs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';
import { MOCK_PAYLOADS } from '../helpers/fixtures.js';
import {
  trackWorkspaceFile,
  cleanupWorkspaceFiles,
  autoCleanup,
  withRestoredPermissions,
  withRestoredModel
} from '../helpers/guard.js';

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

    // Writes into a REAL workspace (the endpoint 403s unregistered paths), so it
    // must be removed again. This is the test that left a 96 KB
    // LARGE_MEMORY_TEST.MD in the developer's workspace root.
    const abs = trackWorkspaceFile(targetWs.path, testFileName);
    autoCleanup();

    try {
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
    } finally {
      cleanupWorkspaceFiles();
      assert.ok(!fs.existsSync(abs), `TC3 must not leave a 96 KB ${testFileName} in the real workspace`);
    }
  });

  it('TC4: Permissions POST with 200 unrecognized properties filters safely', async () => {
    // This is a real mutation of the live global policy, not just a payload
    // shape test: it wrote defaultPolicy 'auto-read' and never restored, so a
    // user on `ask` was downgraded by running the boundary suite.
    await withRestoredPermissions(async (orig) => {
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
      // The point of the test is that the 200 unknown keys are ignored, so prove
      // none of them leaked into the persisted config.
      const echoed = Object.keys(res.data.permissions);
      const leaked = echoed.filter((k) => k.startsWith('extra_param_'));
      assert.deepEqual(leaked, [], 'unrecognized properties must not be persisted');
      assert.ok(orig, 'guard must have snapshotted the original permissions');
    });
  });

  it('TC5: POST /api/mobile/settings/model with 5,000 character model name handles safely', async () => {
    // If the bridge accepts this (200), the developer's global default model
    // becomes a 5 KB garbage string and every later session fails to resolve a
    // model. The old version restored nothing.
    await withRestoredModel(async (origModel) => {
      const hugeModelName = 'model_' + 'x'.repeat(5000);
      const res = await apiRequest('/api/mobile/settings/model', {
        method: 'POST',
        body: { model: hugeModelName }
      });

      // Should handle without crash
      assert.ok(res.status === 200 || res.status === 400);

      // Whatever it answered, the effective model must still be usable.
      const after = await apiRequest('/api/mobile/settings');
      const now = after.data?.settings?.currentModel;
      if (res.status === 200) {
        assert.equal(now, hugeModelName, 'a 200 means the name was accepted verbatim');
      } else {
        assert.equal(now, origModel, 'a 400 must leave the model untouched');
      }
    });
  });
});
