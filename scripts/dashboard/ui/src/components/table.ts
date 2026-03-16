// Data table with sorting and filtering

export interface Column<T> {
  key: string;
  label: string;
  width?: string;
  render: (row: T) => string;
}

export interface TableOptions<T> {
  columns: Column<T>[];
  maxRows?: number;
  emptyText?: string;
  rowClass?: (row: T) => string;
}

export function createTable<T>(
  container: HTMLElement,
  opts: TableOptions<T>
): {
  setData: (rows: T[]) => void;
  prepend: (row: T) => void;
  clear: () => void;
} {
  const wrapper = document.createElement("div");
  wrapper.className = "overflow-auto h-full";

  const table = document.createElement("table");
  table.className = "table table-xs table-pin-rows w-full";

  // Header
  const thead = document.createElement("thead");
  const headerRow = document.createElement("tr");
  for (const col of opts.columns) {
    const th = document.createElement("th");
    th.className = "bg-base-200 text-base-content/50 font-medium";
    if (col.width) th.style.width = col.width;
    th.textContent = col.label;
    headerRow.appendChild(th);
  }
  thead.appendChild(headerRow);
  table.appendChild(thead);

  const tbody = document.createElement("tbody");
  table.appendChild(tbody);

  wrapper.appendChild(table);
  container.appendChild(wrapper);

  const maxRows = opts.maxRows || 500;

  function renderRow(row: T): HTMLTableRowElement {
    const tr = document.createElement("tr");
    tr.className = opts.rowClass?.(row) || "";
    for (const col of opts.columns) {
      const td = document.createElement("td");
      td.innerHTML = col.render(row);
      tr.appendChild(td);
    }
    return tr;
  }

  return {
    setData(rows: T[]): void {
      tbody.innerHTML = "";
      for (const row of rows.slice(0, maxRows)) {
        tbody.appendChild(renderRow(row));
      }
    },
    prepend(row: T): void {
      const tr = renderRow(row);
      tbody.insertBefore(tr, tbody.firstChild);
      while (tbody.children.length > maxRows) {
        tbody.removeChild(tbody.lastChild!);
      }
    },
    clear(): void {
      tbody.innerHTML = "";
    },
  };
}
