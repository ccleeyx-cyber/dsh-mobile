import { apiRequest, createWsClient } from './e2e/helpers/client.js';
import assert from 'node:assert/strict';

async function runR3AdversarialVerification() {
  console.log('=== STARTING R3 ADVERSARIAL STRESS & VERIFICATION ===\n');

  const wsRes = await apiRequest('/api/mobile/workspaces');
  const targetWs = wsRes.data.workspaces[0];
  const workspaceId = targetWs.workspaceId;

  // -----------------------------------------------------------------
  // Challenge 1: Multi-Client Synchronized Cancellation Broadcast
  // -----------------------------------------------------------------
  console.log('--- CHALLENGE 1: Multi-Client Synchronized Broadcast & State Invariant ---');
  {
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId }
    });
    const sId = sRes.data.sessionId;

    const client1 = await createWsClient();
    const client2 = await createWsClient();
    await Promise.all([
      client1.waitForMessage(m => m.type === 'connected', 3000),
      client2.waitForMessage(m => m.type === 'connected', 3000)
    ]);

    client1.send({ type: 'subscribe_session', sessionId: sId });
    client2.send({ type: 'subscribe_session', sessionId: sId });

    // Submit prompt
    const promptRes = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: sId, text: 'Multi-client sync prompt' }
    });
    assert.equal(promptRes.status, 200);

    // Cancel turn
    const cancelRes = await apiRequest('/api/mobile/sessions/cancel', {
      method: 'POST',
      body: { sessionId: sId }
    });
    assert.equal(cancelRes.status, 200);

    // Poll both clients for the terminal isRunning:false frame rather than
    // sampling after a fixed sleep (see Challenge 2 note).
    const deadline = Date.now() + 3000;
    let last1 = null;
    let last2 = null;
    while (Date.now() < deadline) {
      last1 = client1.messages.filter(m => m.sessionId === sId && m.type === 'session_status').pop();
      last2 = client2.messages.filter(m => m.sessionId === sId && m.type === 'session_status').pop();
      if (last1?.isRunning === false && last2?.isRunning === false) break;
      await new Promise(r => setTimeout(r, 50));
    }

    // Inspect client 1
    const msgs1 = client1.messages.filter(m => m.sessionId === sId);
    const done1 = msgs1.some(m => m.type === 'done');

    // Inspect client 2
    const msgs2 = client2.messages.filter(m => m.sessionId === sId);
    const done2 = msgs2.some(m => m.type === 'done');

    console.log(`[Challenge 1] Client 1: final isRunning=${last1?.isRunning}, done=${done1}`);
    console.log(`[Challenge 1] Client 2: final isRunning=${last2?.isRunning}, done=${done2}`);

    assert.equal(last1?.isRunning, false, 'Client 1 must see isRunning: false');
    assert.equal(done1, true, 'Client 1 must receive done');
    assert.equal(last2?.isRunning, false, 'Client 2 must see isRunning: false');
    assert.equal(done2, true, 'Client 2 must receive done');

    client1.close();
    client2.close();
    await apiRequest('/api/mobile/sessions/delete', { method: 'POST', body: { sessionId: sId, workspaceId } });
    console.log('✅ [Challenge 1 Passed]: Multi-client broadcast clean.\n');
  }

  // -----------------------------------------------------------------
  // Challenge 2: Session Re-usability (Prompt -> Cancel -> Subsequent Prompt)
  // -----------------------------------------------------------------
  console.log('--- CHALLENGE 2: Session Re-usability After Turn Cancellation ---');
  {
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId }
    });
    const sId = sRes.data.sessionId;

    const client = await createWsClient();
    await client.waitForMessage(m => m.type === 'connected', 3000);
    client.send({ type: 'subscribe_session', sessionId: sId });

    // Turn 1: Prompt & Cancel
    await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: sId, text: 'Turn 1 initial prompt' }
    });
    await apiRequest('/api/mobile/sessions/cancel', {
      method: 'POST',
      body: { sessionId: sId }
    });

    await new Promise(r => setTimeout(r, 450)); // Wait beyond sequence fence window (>350ms)

    // Turn 2: New prompt on same session
    const prompt2Res = await apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: sId, text: 'Turn 2 follow-up prompt after cancel' }
    });
    console.log(`[Challenge 2] Turn 2 prompt status: ${prompt2Res.status}, body:`, JSON.stringify(prompt2Res.data));
    assert.equal(prompt2Res.status, 200);
    assert.equal(prompt2Res.data.result?.accepted, true, 'Turn 2 must be accepted');

    // Wait to capture Turn 2 running state.
    // Poll instead of sampling after a fixed delay: the session_status broadcast is
    // asynchronous, so a fixed 200ms sleep could read Turn 1's trailing cancel frame
    // (or arrive before turn/start). Wait for the frame we actually expect.
    const turn2Deadline = Date.now() + 3000;
    let runningMsg = null;
    while (Date.now() < turn2Deadline) {
      runningMsg = client.messages
        .filter(m => m.sessionId === sId && m.type === 'session_status')
        .pop();
      if (runningMsg?.isRunning === true) break;
      await new Promise(r => setTimeout(r, 50));
    }
    console.log(`[Challenge 2] Turn 2 status: isRunning=${runningMsg?.isRunning}`);
    assert.equal(runningMsg?.isRunning, true, 'Turn 2 must activate session with isRunning: true');

    // Cancel Turn 2
    const cancel2Res = await apiRequest('/api/mobile/sessions/cancel', {
      method: 'POST',
      body: { sessionId: sId }
    });
    assert.equal(cancel2Res.status, 200);

    // Poll for the terminal frame (see Challenge 2 note).
    const finalDeadline = Date.now() + 3000;
    let finalMsg = null;
    while (Date.now() < finalDeadline) {
      finalMsg = client.messages
        .filter(m => m.sessionId === sId && m.type === 'session_status')
        .pop();
      if (finalMsg?.isRunning === false) break;
      await new Promise(r => setTimeout(r, 50));
    }
    console.log(`[Challenge 2] Final status after Turn 2 cancel: isRunning=${finalMsg?.isRunning}`);
    assert.equal(finalMsg?.isRunning, false, 'Final status after Turn 2 cancel must be isRunning: false');

    client.close();
    await apiRequest('/api/mobile/sessions/delete', { method: 'POST', body: { sessionId: sId, workspaceId } });
    console.log('✅ [Challenge 2 Passed]: Session cleanly reusable for subsequent turns after cancellation.\n');
  }

  // -----------------------------------------------------------------
  // Challenge 3: Extended Concurrency Burst (20 Cycles with Dynamic Staggers)
  // -----------------------------------------------------------------
  console.log('--- CHALLENGE 3: Extended Concurrency Burst (20 Cycles with Dynamic Staggers) ---');
  let inversions = 0;
  for (let i = 0; i < 20; i++) {
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId }
    });
    const sId = sRes.data.sessionId;

    const client = await createWsClient();
    await client.waitForMessage(m => m.type === 'connected', 3000);
    client.send({ type: 'subscribe_session', sessionId: sId });

    // Dynamic delay between prompt and cancel
    const stagger = (i * 7) % 45; // 0, 7, 14, 21, 28, 35, 42ms...

    const pPromise = apiRequest('/api/mobile/sessions/prompt', {
      method: 'POST',
      body: { sessionId: sId, text: `Staggered prompt cycle ${i} with ${'🚀'.repeat(10)}` }
    });

    if (stagger > 0) {
      await new Promise(r => setTimeout(r, stagger));
    }

    const cPromise = apiRequest('/api/mobile/sessions/cancel', {
      method: 'POST',
      body: { sessionId: sId }
    });

    const [pRes, cRes] = await Promise.all([pPromise, cPromise]);
    assert.equal(cRes.status, 200);

    await new Promise(r => setTimeout(r, 350));

    const statusEvents = client.messages
      .filter(m => m.sessionId === sId && m.type === 'session_status')
      .map(m => m.isRunning);

    const finalStatus = statusEvents[statusEvents.length - 1];
    if (finalStatus === true) {
      inversions++;
      console.log(`  -> ⚠️ Inversion on cycle ${i + 1} (stagger ${stagger}ms): final isRunning is true!`);
    }

    client.close();
    await apiRequest('/api/mobile/sessions/delete', { method: 'POST', body: { sessionId: sId, workspaceId } });
  }

  console.log(`[Challenge 3 Result] Inversions across 20 dynamic stagger cycles: ${inversions}/20`);
  assert.equal(inversions, 0, 'Must have exactly zero inversions across all 20 cycles');
  console.log('✅ [Challenge 3 Passed]: 0/20 race inversions under dynamic network staggers.\n');

  // -----------------------------------------------------------------
  // Challenge 4: Flood 30 Concurrent Cancellations
  // -----------------------------------------------------------------
  console.log('--- CHALLENGE 4: Extreme Flood of 30 Parallel Cancellations ---');
  {
    const sRes = await apiRequest('/api/mobile/sessions/create', {
      method: 'POST',
      body: { workspaceId }
    });
    const sId = sRes.data.sessionId;

    const floodPromises = Array.from({ length: 30 }, () =>
      apiRequest('/api/mobile/sessions/cancel', {
        method: 'POST',
        body: { sessionId: sId }
      })
    );

    const floodResults = await Promise.all(floodPromises);
    const all200 = floodResults.every(r => r.status === 200 && r.data.ok === true);
    console.log(`[Challenge 4] 30 flood cancellations all HTTP 200: ${all200}`);
    assert.equal(all200, true, 'Flood cancellations must all succeed idempotently');

    await apiRequest('/api/mobile/sessions/delete', { method: 'POST', body: { sessionId: sId, workspaceId } });
    console.log('✅ [Challenge 4 Passed]: Flood idempotency verified.\n');
  }

  console.log('=== ALL R3 ADVERSARIAL CHALLENGES COMPLETED SUCCESSFULLY ===');
}

runR3AdversarialVerification().catch(err => {
  console.error('Fatal challenge failure:', err);
  process.exit(1);
});
