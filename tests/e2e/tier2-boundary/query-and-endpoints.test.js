/**
 * Tier 2 Boundary: Query Parameters & Endpoint Edge Cases Verification
 * Features: Path traversal prevention (F4.5), unencoded queries, 404 handling, unsupported HTTP methods, URL normalization
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';

describe('Tier 2 - Query Parameters & Endpoints', () => {

  it('TC1: Memory API rejects path traversal attempts targeting files outside workspace (F4.5)', async () => {
    const wsRes = await apiRequest('/api/mobile/workspaces');
    const targetWs = wsRes.data.workspaces[0];

    // Attempt path traversal via fileName
    const traversalPath = '../../../../Windows/win.ini';
    const res = await apiRequest(
      `/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(targetWs.path)}&fileName=${encodeURIComponent(traversalPath)}`
    );

    // Per F4.5 path traversal prevention, request accessing outside workspace root should be rejected with 400/403
    assert.ok(
      res.status === 400 || res.status === 403 || res.data.ok === false,
      'Path traversal attempt should be rejected with 400/403 error'
    );
  });

  it('TC2: Unencoded special characters in query string are handled safely', async () => {
    const res = await apiRequest('/api/mobile/workspace/memory?workspacePath=C:\\test%20folder&fileName=USER%20GUIDE.MD');
    // Should parse and return response without 500 crash (403 for unregistered workspace)
    assert.ok(res.status === 200 || res.status === 400 || res.status === 403);

  });

  it('TC3: Non-existent endpoint returns HTTP 404 with JSON error object', async () => {
    const res = await apiRequest('/api/mobile/completely-unknown-route');
    assert.equal(res.status, 404);
    assert.ok(res.data.error, 'Response should contain error description');
  });

  it('TC4: Unsupported HTTP method on permissions endpoint returns HTTP 404 or 405 without hanging', async () => {
    const res = await apiRequest('/api/mobile/permissions', {
      method: 'DELETE'
    });
    // Bridge should not hang or crash
    assert.ok(res.status === 404 || res.status === 405 || res.status === 400);
  });

  it('TC5: Repeated slashes in endpoint path are handled safely', async () => {
    const res = await apiRequest('//api///mobile//workspaces');
    // Should return 200 or 404 cleanly without crashing server
    assert.ok(res.status === 200 || res.status === 404);
  });
});
