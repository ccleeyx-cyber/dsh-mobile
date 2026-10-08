import fs from 'node:fs';
import path from 'node:path';
import { homedir } from 'node:os';
import { performance } from 'node:perf_hooks';
import { apiRequest, createWsClient } from '../helpers/client.js';

async function runBurstStress() {
  const permDir = process.env.DSH_HOME 
    ? path.join(process.env.DSH_HOME, 'mobile-access') 
    : path.join(homedir(), '.dsh', 'mobile-access');
  const permFile = path.join(permDir, 'permissions.json');

  const CLIENT_COUNT = 15;
  const BURST_COUNT = 50;
  console.log(`[BurstStress] Connecting ${CLIENT_COUNT} concurrent WS clients...`);

  const clients = [];
  for (let i = 0; i < CLIENT_COUNT; i++) {
    clients.push(await createWsClient({ timeout: 5000 }));
  }

  let totalFramesReceived = 0;
  clients.forEach(c => {
    c.ws.addEventListener('message', ev => {
      try {
        const d = JSON.parse(ev.data);
        if (d.type === 'permission_updated') {
          totalFramesReceived++;
        }
      } catch (_) {}
    });
  });

  console.log(`[BurstStress] Firing ${BURST_COUNT} parallel HTTP POST requests simultaneously...`);
  const t0 = performance.now();
  const requests = [];
  const policies = ['danger-full-access', 'workspace-write', 'auto-read', 'ask'];

  for (let i = 0; i < BURST_COUNT; i++) {
    const pol = policies[i % policies.length];
    const sId = `burst-session-${i}`;
    if (i % 2 === 0) {
      requests.push(
        apiRequest('/api/mobile/permissions', {
          method: 'POST',
          body: { defaultPolicy: pol, maxSteps: 30 + (i % 20), protectGit: i % 2 === 0 }
        })
      );
    } else {
      requests.push(
        apiRequest('/api/mobile/sessions/permission', {
          method: 'POST',
          body: { sessionId: sId, policy: pol }
        })
      );
    }
  }

  const results = await Promise.all(requests);
  const burstDuration = performance.now() - t0;
  console.log(`[BurstStress] ${BURST_COUNT} requests completed in ${burstDuration.toFixed(2)} ms.`);

  // Check HTTP statuses
  let httpFailures = 0;
  for (const r of results) {
    if (r.status !== 200 || !r.data.ok) {
      httpFailures++;
    }
  }
  console.log(`[BurstStress] HTTP 200 Success: ${results.length - httpFailures}/${results.length}`);

  // Allow WS messages to arrive
  await new Promise(r => setTimeout(r, 500));

  // Inspect disk integrity
  const rawDisk = fs.readFileSync(permFile, 'utf8');
  let diskJson;
  let jsonValid = true;
  try {
    diskJson = JSON.parse(rawDisk);
  } catch (err) {
    jsonValid = false;
    console.error('[BurstStress] JSON parse failure on disk:', err);
  }

  const tmpFiles = fs.readdirSync(permDir).filter(f => f.includes('.tmp'));
  const memState = (await apiRequest('/api/mobile/permissions')).data.permissions;

  console.log(`--- BURST STRESS SUMMARY ---`);
  console.log(`Burst Request Throughput: ${(BURST_COUNT / (burstDuration / 1000)).toFixed(2)} req/sec`);
  console.log(`Total WS Broadcast Frames Received: ${totalFramesReceived}`);
  console.log(`Average Frames Per Client: ${(totalFramesReceived / CLIENT_COUNT).toFixed(2)}`);
  console.log(`Disk JSON Valid: ${jsonValid}`);
  console.log(`Disk Execution Policy: ${diskJson?.executionPolicy}`);
  console.log(`Memory Execution Policy: ${memState?.executionPolicy}`);
  console.log(`Policy Matches: ${diskJson?.executionPolicy === memState?.executionPolicy}`);
  console.log(`Orphaned tmp files: ${tmpFiles.length}`);

  for (const c of clients) {
    await c.close();
  }

  if (httpFailures > 0 || !jsonValid || tmpFiles.length > 0) {
    throw new Error('Burst stress test encountered failures');
  }
}

runBurstStress().catch(err => {
  console.error(err);
  process.exit(1);
});
