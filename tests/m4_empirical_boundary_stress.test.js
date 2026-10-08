import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { apiRequest } from './e2e/helpers/client.js';
import { CONFIG } from './e2e/helpers/fixtures.js';

describe('M4 Empirical Boundary & Security Invariants Challenge', () => {

  describe('1. 2MB Payload Cap Verification', () => {

    it('Stream request exceeding 2MB (2.5MB payload) must abort with HTTP 413 before memory buffering', async () => {
      const oversizedPayload = JSON.stringify({
        sessionId: 'test-session',
        text: 'X'.repeat(2.5 * 1024 * 1024)
      });

      // Using raw http.request to observe exact status code and headers without fetch abstraction masking
      const url = new URL('/api/mobile/sessions/prompt', CONFIG.BASE_URL);
      const res = await new Promise((resolve, reject) => {
        const req = http.request(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(oversizedPayload),
            'Authorization': `Bearer ${CONFIG.VALID_TOKEN}`
          }
        }, (response) => {
          let data = '';
          response.on('data', chunk => data += chunk);
          response.on('end', () => resolve({ status: response.statusCode, data }));
        });

        req.on('error', (err) => resolve({ error: err }));
        req.write(oversizedPayload);
        req.end();
      });

      // Assert status 413
      assert.equal(res.status, 413, `Expected HTTP 413 for 2.5MB payload, received ${res.status || res.error}`);
    });

    it('Chunked stream request exceeding 2MB without Content-Length aborts with HTTP 413', async () => {
      const url = new URL('/api/mobile/permissions', CONFIG.BASE_URL);
      const res = await new Promise((resolve) => {
        const req = http.request(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Transfer-Encoding': 'chunked',
            'Authorization': `Bearer ${CONFIG.VALID_TOKEN}`
          }
        }, (response) => {
          let data = '';
          response.on('data', chunk => data += chunk);
          response.on('end', () => resolve({ status: response.statusCode, data }));
        });

        req.on('error', (err) => resolve({ error: err }));

        // Send 3 chunks of 800KB each (2.4MB total)
        const chunk = Buffer.alloc(800 * 1024, 'a');
        req.write(chunk);
        req.write(chunk);
        req.write(chunk);
        req.end();
      });

      assert.equal(res.status, 413, `Expected HTTP 413 for chunked streaming > 2MB, received ${res.status || res.error}`);
    });

    it('Payload of exactly 1.9MB (below 2MB) is NOT rejected with 413', async () => {
      const safePayload = JSON.stringify({
        defaultPolicy: 'auto-read',
        padding: 'Y'.repeat(1.9 * 1024 * 1024)
      });

      const url = new URL('/api/mobile/permissions', CONFIG.BASE_URL);
      const res = await new Promise((resolve) => {
        const req = http.request(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Content-Length': Buffer.byteLength(safePayload),
            'Authorization': `Bearer ${CONFIG.VALID_TOKEN}`
          }
        }, (response) => {
          let data = '';
          response.on('data', chunk => data += chunk);
          response.on('end', () => resolve({ status: response.statusCode, data }));
        });

        req.on('error', (err) => resolve({ error: err }));
        req.write(safePayload);
        req.end();
      });

      assert.notEqual(res.status, 413, `Payload under 2MB should not receive HTTP 413`);
      assert.equal(res.status, 200);
    });
  });

  describe('2. Directory Traversal Hardening Verification', () => {

    it('Relative navigation traversal ".." in fileName returns HTTP 403 Forbidden', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const wsPath = wsRes.data.workspaces[0]?.path || 'C:\\test';

      const res = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(wsPath)}&fileName=..`);
      assert.equal(res.status, 403, `Expected HTTP 403 Forbidden for "..", received ${res.status}`);
    });

    it('Relative navigation traversal "../" in fileName returns HTTP 403 Forbidden', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const wsPath = wsRes.data.workspaces[0]?.path || 'C:\\test';

      const res = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(wsPath)}&fileName=../escape.txt`);
      assert.equal(res.status, 403, `Expected HTTP 403 Forbidden for "../escape.txt", received ${res.status}`);
    });

    it('Relative navigation traversal "..\\" in fileName returns HTTP 403 Forbidden', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const wsPath = wsRes.data.workspaces[0]?.path || 'C:\\test';

      const res = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(wsPath)}&fileName=..\\escape.txt`);
      assert.equal(res.status, 403, `Expected HTTP 403 Forbidden for "..\\escape.txt", received ${res.status}`);
    });

    it('Absolute POSIX path in fileName returns HTTP 403 Forbidden', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const wsPath = wsRes.data.workspaces[0]?.path || 'C:\\test';

      const res = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(wsPath)}&fileName=/etc/passwd`);
      assert.equal(res.status, 403, `Expected HTTP 403 Forbidden for "/etc/passwd", received ${res.status}`);
    });

    it('Absolute Windows path with drive letter in fileName returns HTTP 403 Forbidden', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const wsPath = wsRes.data.workspaces[0]?.path || 'C:\\test';

      const res = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(wsPath)}&fileName=C:\\Windows\\win.ini`);
      assert.equal(res.status, 403, `Expected HTTP 403 Forbidden for "C:\\Windows\\win.ini", received ${res.status}`);
    });

    it('Windows drive letter with forward slash "C:/..." returns HTTP 403 Forbidden', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const wsPath = wsRes.data.workspaces[0]?.path || 'C:\\test';

      const res = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(wsPath)}&fileName=C:/Windows/win.ini`);
      assert.equal(res.status, 403, `Expected HTTP 403 Forbidden for "C:/Windows/win.ini", received ${res.status}`);
    });

    it('POST /api/mobile/workspace/memory directory traversal returns HTTP 403 Forbidden', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const wsPath = wsRes.data.workspaces[0]?.path || 'C:\\test';

      const res = await apiRequest('/api/mobile/workspace/memory', {
        method: 'POST',
        body: {
          workspacePath: wsPath,
          fileName: '../../../../Windows/malicious.txt',
          content: 'malicious'
        }
      });
      assert.equal(res.status, 403, `Expected HTTP 403 Forbidden on POST traversal, received ${res.status}`);
    });
  });

  describe('3. Whitespace & Empty Prompts Rejection', () => {

    it('Empty sessionId ("") returns HTTP 400', async () => {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: '', text: 'Valid prompt' }
      });
      assert.equal(res.status, 400, `Expected HTTP 400 for empty sessionId, received ${res.status}`);
      assert.match(res.data?.error || '', /sessionId/i);
    });

    it('Whitespace-only sessionId ("   ") returns HTTP 400', async () => {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: '   \t  ', text: 'Valid prompt' }
      });
      assert.equal(res.status, 400, `Expected HTTP 400 for whitespace sessionId, received ${res.status}`);
      assert.match(res.data?.error || '', /sessionId/i);
    });

    it('Missing/null sessionId returns HTTP 400', async () => {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { text: 'Valid prompt' }
      });
      assert.equal(res.status, 400, `Expected HTTP 400 for missing sessionId, received ${res.status}`);
    });

    it('Empty prompt text ("") returns HTTP 400', async () => {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: 'valid-session-id', text: '' }
      });
      assert.equal(res.status, 400, `Expected HTTP 400 for empty prompt text, received ${res.status}`);
      assert.match(res.data?.error || '', /prompt text/i);
    });

    it('Whitespace-only prompt text ("   ") returns HTTP 400', async () => {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: 'valid-session-id', text: '  \t  \n  ' }
      });
      assert.equal(res.status, 400, `Expected HTTP 400 for whitespace-only prompt, received ${res.status}`);
      assert.match(res.data?.error || '', /prompt text/i);
    });

    it('Missing prompt text returns HTTP 400', async () => {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: 'valid-session-id' }
      });
      assert.equal(res.status, 400, `Expected HTTP 400 for missing prompt, received ${res.status}`);
    });

    it('Object prompt with whitespace-only content ({ text: "  " }) returns HTTP 400', async () => {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: 'valid-session-id', prompt: { text: '   ' } }
      });
      assert.equal(res.status, 400, `Expected HTTP 400 for object prompt with whitespace text, received ${res.status}`);
    });
  });
});
