/**
 * Tier 4 Workload 5: Mobile Developer Workspace & Memory Management Workflow
 * Simulation of user inspecting project instructions (MEMORY.md/USER.MD), updating guidelines, and verifying persistence
 *
 * ⚠️ DESTRUCTIVE SUITE — writes a scratch instruction file into a REAL
 * registered workspace. Run via `npm run test:destructive`.
 *
 * MW-5 previously left PROJECT_WORKLOAD_MEMORY.MD behind in the developer's own
 * workspace root on every run. The memory endpoint validates workspacePath
 * against the registered-workspace whitelist, so a temp dir is not an option —
 * the file has to be tracked and deleted instead.
 */

import fs from 'node:fs';
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { apiRequest } from '../helpers/client.js';
import { trackWorkspaceFile, cleanupWorkspaceFiles, autoCleanup } from '../helpers/guard.js';

describe('Tier 4 Workload 5 - Developer Workspace & Memory Management', () => {

  it('MW-5: End-to-end workspace instruction inspection, update, and file persistence workflow', async () => {
    // Step 1: Query workspaces and select target workspace
    const wsRes = await apiRequest('/api/mobile/workspaces');
    assert.equal(wsRes.status, 200);
    const targetWs = wsRes.data.workspaces[0];

    // Step 2: Read current memory file
    const memoryFileName = 'PROJECT_WORKLOAD_MEMORY.MD';
    const abs = trackWorkspaceFile(targetWs.path, memoryFileName);
    autoCleanup();

    try {
      const initialRead = await apiRequest(
        `/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(targetWs.path)}&fileName=${memoryFileName}`
      );
      assert.equal(initialRead.status, 200);

      // Step 3: Write new project guidelines from mobile client
      const updatedContent = `# Mobile Control Guidelines\nUpdated at: ${new Date().toISOString()}\n- Touch optimizations enabled\n- Auto-scroll active\n`;
      const saveRes = await apiRequest('/api/mobile/workspace/memory', {
        method: 'POST',
        body: {
          workspacePath: targetWs.path,
          fileName: memoryFileName,
          content: updatedContent
        }
      });

      assert.equal(saveRes.status, 200);
      assert.equal(saveRes.data.ok, true);

      // Step 4: Re-read and verify persistence
      const verifyRead = await apiRequest(
        `/api/mobile/workspace/memory?workspacePath=${encodeURIComponent(targetWs.path)}&fileName=${memoryFileName}`
      );
      assert.equal(verifyRead.status, 200);
      assert.equal(verifyRead.data.content, updatedContent);
      assert.equal(verifyRead.data.exists, true);

      // Step 5: Verify audit log endpoint returns valid array
      const auditRes = await apiRequest('/api/mobile/audit-logs');
      assert.equal(auditRes.status, 200);
      const logs = auditRes.data.logs || auditRes.data.auditLogs;
      assert.ok(Array.isArray(logs));
    } finally {
      cleanupWorkspaceFiles();
      assert.ok(!fs.existsSync(abs), `MW-5 must not leave ${memoryFileName} in the real workspace`);
    }
  });

  it('MW-5-Audit: Workspace memory update triggers persistent audit trail record (F2.4 audit requirement)', async () => {
    const auditRes = await apiRequest('/api/mobile/audit-logs');
    assert.equal(auditRes.status, 200);
    const logs = auditRes.data.logs || auditRes.data.auditLogs;
    assert.ok(Array.isArray(logs));

    // Exposes known stub in lib/store.mjs readAudit() returning []
    const memoryLog = logs.find(l => l.action === 'memory/update' || l.event === 'memory/update' || l.toolName === 'memory/update');
    assert.ok(memoryLog, 'Audit log should record memory update action (F2.4 audit trail requirement)');
  });
});
