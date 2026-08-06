// Minimal WASI (wasi_snapshot_preview1) shim shared by the browser playground
// (index.html) and the Node instantiation smoke test (tests/wasm_smoke.mjs).
// Keeping both consumers on one module means CI exercises the exact shim the
// playground ships — an unshimmed import fails the smoke test before it can
// break the deployed site (see issue #48).
//
// The Zig std library imports ~27 wasi_snapshot_preview1 functions transitively
// (random_get, clock_time_get, environ_*, and many fd_*/path_* operations),
// even though rendering is deterministic and touches none of them. Every field
// the module imports must resolve to a Function or WebAssembly.instantiate
// throws a LinkError. We implement the few that could actually run and let a
// Proxy return a harmless EBADF stub for everything else — so the module links
// regardless of which imports a future std pulls in.

const WASI_OK = 0, WASI_BADF = 8;

/// Build a WASI import object. `getBuffer` must return the instance's current
/// `memory.buffer` (looked up per call — the buffer detaches when wasm memory
/// grows, so it must never be cached).
export function makeWasiShim(getBuffer) {
  const wasiImpl = {
    fd_write(fd, iov, n, nw) {
      const v = new DataView(getBuffer()); let w = 0;
      for (let i = 0; i < n; i++) {
        const b = v.getUint32(iov + i*8, true), l = v.getUint32(iov + i*8+4, true);
        if (fd === 2) console.warn('[wasm]', new TextDecoder().decode(new Uint8Array(getBuffer(), b, l)));
        w += l;
      }
      v.setUint32(nw, w, true); return WASI_OK;
    },
    // Fill the buffer with cryptographically-random bytes (chunked to respect
    // crypto.getRandomValues' 65536-byte cap).
    random_get(ptr, len) {
      let off = 0;
      while (off < len) {
        const chunk = Math.min(len - off, 65536);
        crypto.getRandomValues(new Uint8Array(getBuffer(), ptr + off, chunk));
        off += chunk;
      }
      return WASI_OK;
    },
    clock_time_get(_id, _precision, out) {
      new DataView(getBuffer()).setBigUint64(out, BigInt(Date.now()) * 1000000n, true); // ns since epoch
      return WASI_OK;
    },
    clock_res_get(_id, out) {
      new DataView(getBuffer()).setBigUint64(out, 1000000n, true);
      return WASI_OK;
    },
    environ_sizes_get(countOut, sizeOut) {
      const v = new DataView(getBuffer());
      v.setUint32(countOut, 0, true); v.setUint32(sizeOut, 0, true);
      return WASI_OK;
    },
    environ_get() { return WASI_OK; },
    proc_exit(code) { throw new Error('wasm called proc_exit(' + code + ')'); },
  };
  return {
    wasi_snapshot_preview1: new Proxy(wasiImpl, {
      get: (target, name) => target[name] ?? (() => WASI_BADF),
    }),
  };
}
