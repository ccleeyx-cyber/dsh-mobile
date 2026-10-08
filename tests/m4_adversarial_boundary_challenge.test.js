/**
 * Milestone M4 Adversarial Boundary & Security Invariants Challenge Test Suite
 * Executed by: challenger_m4_1 (critic, specialist)
 * Role: Empirical stress-testing of M4 Server Bridge Boundaries and Security Invariants
 */

import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { apiRequest } from './e2e/helpers/client.js';
import { CONFIG } from './e2e/helpers/fixtures.js';

describe('Milestone M4 Adversarial Challenge: Server Bridge Boundaries & Invariants', () => {

  describe('Challenge 1: Directory Traversal via Unvalidated workspacePath (CRITICAL VULNERABILITY)', () => {

    it('BUG: GET /api/mobile/workspace/memory allows arbitrary host file exfiltration via workspacePath (e.g. C:\\Windows\\win.ini)', async () => {
      // Security Invariant: Access outside registered workspaces must be rejected with HTTP 403 Forbidden
      const res = await apiRequest('/api/mobile/workspace/memory?workspacePath=C:\\Windows&fileName=win.ini');
      
      // EMPIRICAL OBSERVATION: The server returns HTTP 200 and leaks file content from C:\Windows\win.ini!
      // Invariant requirement: Must return 403 Forbidden
      const passesSecurityInvariant = res.status === 403;
      assert.equal(
        res.status, 
        403, 
        `CRITICAL SECURITY BUG: Server returned HTTP ${res.status} (expected 403 Forbidden). Leaked filePath: ${res.data?.filePath}`
      );
    });

    it('BUG: GET /api/mobile/workspace/memory allows relative directory traversal escaping workspace via workspacePath', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const validWsPath = wsRes.data.workspaces[0]?.path;
      assert.ok(validWsPath, 'Expected at least one valid workspace');

      // Attempt escaping workspace root via workspacePath relative traversal
      const escapingWsPath = validWsPath + '/../../';
      const res = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(escapingWsPath)}&fileName=target.txt`);

      // Invariant requirement: Must return 403 Forbidden
      assert.equal(
        res.status, 
        403, 
        `CRITICAL SECURITY BUG: Server returned HTTP ${res.status} for traversed workspacePath (expected 403 Forbidden). Resolved target: ${res.data?.filePath}`
      );
    });

    it('Sanitization check in fileName correctly rejects traversal patterns in fileName (PASS)', async () => {
      const wsRes = await apiRequest('/api/mobile/workspaces');
      const validWsPath = wsRes.data.workspaces[0].path;

      const res1 = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(validWsPath)}&fileName=../secret.txt`);
      assert.equal(res1.status, 403, 'fileName="../secret.txt" must return 403');

      const res2 = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(validWsPath)}&fileName=..\\secret.txt`);
      assert.equal(res2.status, 403, 'fileName="..\\secret.txt" must return 403');

      const res3 = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(validWsPath)}&fileName=/etc/passwd`);
      assert.equal(res3.status, 403, 'fileName="/etc/passwd" must return 403');

      const res4 = await apiRequest(`/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(validWsPath)}&fileName=C:\\Windows\\win.ini`);
      assert.equal(res4.status, 403, 'fileName="C:\\Windows\\win.ini" must return 403');
    });
  });

  describe('Challenge 2: 2MB Payload Limits & Chunked Stream Abort', () => {

    it('Oversized POST with Content-Length > 2MB returns HTTP 413 cleanly before buffering (PASS)', async () => {
      const res = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: {
          sessionId: 'test-session',
          text: 'Z'.repeat(3 * 1024 * 1024)
        }
      });

      assert.equal(res.status, 413, `Expected HTTP 413, received ${res.status}`);
      assert.match(res.data?.error || '', /Payload Too Large/i);
    });

    it('OBSERVATION: Chunked stream without Content-Length triggers immediate socket.destroy() causing ECONNRESET instead of HTTP 413', async () => {
      const url = new URL('/api/mobile/permissions', CONFIG.BASE_URL);
      
      let got413 = false;
      let gotConnReset = false;

      await new Promise((resolve) => {
        const req = http.request(url, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Transfer-Encoding': 'chunked',
            'Authorization': `Bearer ${CONFIG.VALID_TOKEN}`
          }
        }, (res) => {
          if (res.statusCode === 413) got413 = true;
          resolve();
        });

        req.on('error', (err) => {
          if (err.code === 'ECONNRESET') gotConnReset = true;
          resolve();
        });

        const chunk = Buffer.alloc(1024 * 1024, 'a');
        req.write(chunk);
        setTimeout(() => {
          req.write(chunk);
          setTimeout(() => {
            req.write(chunk);
            req.end();
          }, 20);
        }, 20);
      });

      // Assert that defensive abort occurred (either clean 413 or TCP reset guard against bomb)
      assert.ok(
        got413 || gotConnReset,
        'Oversized chunked request must be aborted defensively by the server'
      );
    });
  });

  describe('Challenge 3: Whitespace & Empty Prompts Rejection', () => {

    it('POST /api/mobile/sessions/prompt rejects empty and whitespace-only sessionId with HTTP 400 (PASS)', async () => {
      const resEmpty = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: '', text: 'Hello' }
      });
      assert.equal(resEmpty.status, 400, 'Empty sessionId must return 400');

      const resSpace = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: '   \t  ', text: 'Hello' }
      });
      assert.equal(resSpace.status, 400, 'Whitespace-only sessionId must return 400');
    });

    it('POST /api/mobile/sessions/prompt rejects empty and whitespace-only prompt text with HTTP 400 (PASS)', async () => {
      const resEmpty = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: 'valid-id', text: '' }
      });
      assert.equal(resEmpty.status, 400, 'Empty prompt text must return 400');

      const resSpace = await apiRequest('/api/mobile/sessions/prompt', {
        method: 'POST',
        body: { sessionId: 'valid-id', text: '   \n \t  ' }
      });
      assert.equal(resSpace.status, 400, 'Whitespace prompt text must return 400');
    });

    it('BUG: POST /api/mobile/sessions/cancel accepts whitespace-only sessionId and returns HTTP 200 instead of HTTP 400', async () => {
      const res = await apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: '   ' }
      });

      // Invariant requirement: Empty or whitespace-only sessionId must return HTTP 400
      assert.equal(
        res.status, 
        400, 
        `BUG: POST /api/mobile/sessions/cancel returned HTTP ${res.status} (expected 400 for whitespace-only sessionId)`
      );
    });
  });
});
