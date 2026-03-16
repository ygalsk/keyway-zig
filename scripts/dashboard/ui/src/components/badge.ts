// Method and status badges

export function methodBadge(method: string): string {
  return `<span class="method-${method} font-semibold">${method}</span>`;
}

export function statusBadge(status: number): string {
  let cls = "text-base-content/50";
  if (status >= 200 && status < 300) cls = "status-2xx";
  else if (status >= 300 && status < 400) cls = "status-3xx";
  else if (status >= 400 && status < 500) cls = "status-4xx";
  else if (status >= 500) cls = "status-5xx";
  return `<span class="${cls}">${status}</span>`;
}
