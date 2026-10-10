import fs from 'node:fs';
import path from 'node:path';

/**
 * Stream one file to an HTTP response.
 *
 * Extracted from `index.js` on purpose. There it lived inside the plugin
 * factory and referenced `res` as a free variable, so every call threw
 * `ReferenceError: res is not defined` — the downloads route answered 500 for
 * every deliverable, which is exactly what the user saw as "点不开 / 下载不成功".
 *
 * The unit tests could not catch it because `sendFile` was only ever injected as
 * a two-argument stub (`async (p, name) => true`) that needed neither `res` nor a
 * real response object: the route tests were green against a fake that did not
 * resemble the real function at all. Moving it here means the tests import the
 * real implementation and drive it with a fake `res`.
 *
 * @param res - the HTTP response to write to. Must be the first argument: this
 *   function is useless without a response, and making it a parameter is what
 *   removes the free-variable hazard by construction.
 * @param absPath - absolute path of the file to send.
 * @param displayName - name offered to the client; defaults to the file's own
 *   basename. Percent-encoded per RFC 5987 so non-ASCII names survive.
 * @returns Promise<true> once the bytes are on the wire, Promise<false> when
 *   nothing could be sent (missing path, not a regular file, read error). On
 *   false it writes **nothing** — a partially-written 200 would be worse than an
 *   error the client can see. The caller owns the error response; a caller that
 *   ignores the return value leaves the socket open with no answer and the phone
 *   waits out its full request timeout (that is what "点不开" looked like).
 */
export function sendFile(res, absPath, displayName) {
  return new Promise((resolve) => {
    let stat;
    try {
      stat = fs.statSync(absPath);
    } catch {
      resolve(false);
      return;
    }
    if (!stat.isFile()) {
      resolve(false);
      return;
    }
    const safeName = encodeURIComponent(path.basename(displayName || absPath));
    res.writeHead(200, {
      'Content-Type': 'application/octet-stream',
      'Content-Length': stat.size,
      'Content-Disposition': `attachment; filename*=UTF-8''${safeName}`
    });
    const stream = fs.createReadStream(absPath);
    // A read error mid-flight has already sent headers, so the only honest
    // recovery is to tear the connection down and report failure.
    stream.on('error', () => { try { res.destroy(); } catch (_) {} resolve(false); });
    stream.on('end', () => resolve(true));
    stream.pipe(res);
  });
}
