// Hash-based routing utilities

export function parseHash(hash: string): { path: string; query: URLSearchParams } {
  const raw = hash.slice(1) || "/";
  const qIdx = raw.indexOf("?");
  if (qIdx === -1) return { path: raw, query: new URLSearchParams() };
  return { path: raw.slice(0, qIdx), query: new URLSearchParams(raw.slice(qIdx + 1)) };
}

export function getHashParams(): URLSearchParams {
  return parseHash(location.hash).query;
}
