import fs from 'node:fs';
import path from 'node:path';
import { homedir } from 'node:os';
import { performance } from 'node:perf_hooks';
import { apiRequest, createWsClient } from '../helpers/client.js';

async function runBenchmark() {
  const permDir = process.env.DSH_HOME 
    ? path.join(process.env.DSH_HOME, 'mobile-access') 
    : path.join(homedir(), '.dsh', 'mobile-access');
  const permFile = path.join(permDir, 'permissions.json');

  const CLIENT_COUNT = 10;
  const TOGGLE_COUNT = 30;
  console.log(`[Benchmark] Starting stress benchmark with ${CLIENT_COUNT} concurrent WS clients and ${TOGGLE_COUNT} high-frequency policy toggles...`);

  // Connect 10 WebSocket clients
  const clients = [];
  for (let i = 0; i < CLIENT_COUNT; i++) {
    const c = await createWsClient({ timeout: 5000 });
    clients.push(c);
  }
  console.log(`[Benchmark] ${CLIENT_COUNT} clients connected and handshaked.`);

  const latencies = [];
  const policies = ['danger-full-access', 'workspace-write', 'auto-read'];

  for (let round = 0; round < TOGGLE_COUNT; round++) {
    const pol = policies[round % policies.length];
    const sId = `bench-session-${round % 5}`;

    const waiters = clients.map(client => {
      return new Promise((resolve) => {
        const handler = (event) => {
          try {
            const data = JSON.parse(event.data);
            if (data.type === 'permission_updated') {
              const recvTime = performance.now();
              client.ws.removeEventListener('message', handler);
              resolve(recvTime);
            }
          } catch (_) {}
        };
        client.ws.addEventListener('message', handler);
      });
    });

    const startTime = performance.now();
    // Alternating between global policy and session policy
    if (round % 2 === 0) {
      await apiRequest('/api/mobile/permissions', {
        method: 'POST',
        body: { defaultPolicy: pol, maxSteps: 20 + (round % 10) }
      });
    } else {
      await apiRequest('/api/mobile/sessions/permission', {
        method: 'POST',
        body: { sessionId: sId, policy: pol }
      });
    }

    const recvTimes = await Promise.all(waiters);
    for (const t of recvTimes) {
      latencies.push(t - startTime);
    }

    // Inspect disk every 5 rounds
    if (round % 5 === 0) {
      const raw = fs.readFileSync(permFile, 'utf8');
      JSON.parse(raw); // asserts valid JSON
    }
  }

  // Cleanup clients
  for (const c of clients) {
    await c.close();
  }

  // Calculate statistics
  latencies.sort((a, b) => a - b);
  const min = latencies[0];
  const max = latencies[latencies.length - 1];
  const sum = latencies.reduce((acc, v) => acc + v, 0);
  const mean = sum / latencies.length;
  const p50 = latencies[Math.floor(latencies.length * 0.5)];
  const p95 = latencies[Math.floor(latencies.length * 0.95)];
  const p99 = latencies[Math.floor(latencies.length * 0.99)];

  // Check orphaned files
  const tmpFiles = fs.readdirSync(permDir).filter(f => f.includes('.tmp'));

  console.log(`--- BENCHMARK RESULTS ---`);
  console.log(`Total frame samples: ${latencies.length} (${CLIENT_COUNT} clients x ${TOGGLE_COUNT} toggles)`);
  console.log(`Min Latency: ${min.toFixed(2)} ms`);
  console.log(`Mean Latency: ${mean.toFixed(2)} ms`);
  console.log(`P50 Latency: ${p50.toFixed(2)} ms`);
  console.log(`P95 Latency: ${p95.toFixed(2)} ms`);
  console.log(`P99 Latency: ${p99.toFixed(2)} ms`);
  console.log(`Max Latency: ${max.toFixed(2)} ms`);
  console.log(`50ms SLA Compliance: ${(latencies.filter(l => l <= 50).length / latencies.length * 100).toFixed(2)}%`);
  console.log(`Orphaned tmp files on disk: ${tmpFiles.length}`);

  // Final disk check
  const finalDisk = JSON.parse(fs.readFileSync(permFile, 'utf8'));
  const finalMem = (await apiRequest('/api/mobile/permissions')).data.permissions;
  const memoryDiskMatch = finalDisk.executionPolicy === finalMem.executionPolicy;
  console.log(`Disk vs Memory consistency: ${memoryDiskMatch ? 'MATCHED' : 'MISMATCH'}`);

  if (max > 50) {
    console.warn(`WARNING: Max latency ${max.toFixed(2)}ms exceeded 50ms SLA`);
  }
}

runBenchmark().catch(err => {
  console.error('[Benchmark Error]', err);
  process.exit(1);
});
