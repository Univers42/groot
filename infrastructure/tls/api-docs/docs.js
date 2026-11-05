// Renders /openapi.json as one table per tag. Plain DOM and textContent: no third-party
// renderer to fetch, and nothing in the document can inject markup.
const METHODS = ['get', 'post', 'put', 'patch', 'delete'];

function el(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function operationsByTag(spec) {
  const groups = new Map();
  for (const [path, item] of Object.entries(spec.paths || {})) {
    for (const method of METHODS) {
      const op = item[method];
      if (!op) continue;
      const tag = (op.tags && op.tags[0]) || 'other';
      if (!groups.has(tag)) groups.set(tag, []);
      groups.get(tag).push({ method, path, op });
    }
  }
  return groups;
}

function operationRow({ method, path, op }) {
  const row = el('tr');
  row.append(el('td', method.toUpperCase(), `method ${method}`));
  const cell = el('td');
  cell.append(el('code', path));
  row.append(cell);
  const what = el('td', op.summary || '');
  const params = (op.parameters || []).map((p) => `${p.name} (${p.in})`);
  if (params.length) what.append(el('div', `Parameters: ${params.join(', ')}`, 'muted'));
  row.append(what);
  row.append(el('td', Object.keys(op.responses || {}).join(', ')));
  return row;
}

function render(spec) {
  document.getElementById('title').textContent = `${spec.info.title} ${spec.info.version}`;
  document.getElementById('summary').textContent = spec.info.summary || '';
  const tags = new Map((spec.tags || []).map((t) => [t.name, t.description]));
  const root = document.getElementById('operations');
  let count = 0;
  for (const [tag, ops] of operationsByTag(spec)) {
    root.append(el('h3', tag));
    if (tags.get(tag)) root.append(el('p', tags.get(tag), 'muted'));
    const table = el('table');
    const head = el('tr');
    for (const h of ['Method', 'Path', 'What it does', 'Responses']) head.append(el('th', h));
    table.append(head);
    for (const op of ops) table.append(operationRow(op));
    root.append(table);
    count += ops.length;
  }
  document.getElementById('status').textContent = `${count} operations.`;
}

fetch('/openapi.json')
  .then((r) => (r.ok ? r.json() : Promise.reject(new Error(`HTTP ${r.status}`))))
  .then(render)
  .catch((err) => {
    document.getElementById('status').textContent = `Could not load /openapi.json: ${err.message}`;
  });
