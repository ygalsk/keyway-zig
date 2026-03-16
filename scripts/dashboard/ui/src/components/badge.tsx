// Method and status badges — JSX components

export function MethodBadge(props: { method: string }) {
  return (
    <span class={`method-${props.method} font-semibold inline-block w-[52px] text-center shrink-0`}>
      {props.method}
    </span>
  );
}

export function StatusBadge(props: { status: number }) {
  const cls = () => {
    const s = props.status;
    if (s >= 200 && s < 300) return "status-2xx";
    if (s >= 300 && s < 400) return "status-3xx";
    if (s >= 400 && s < 500) return "status-4xx";
    if (s >= 500) return "status-5xx";
    return "text-base-content/50";
  };
  return <span class={cls()}>{props.status}</span>;
}
