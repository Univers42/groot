// Renders a dataset (full or spike) to the files the loader reads, as strings keyed by file name.
import { renderSchema, renderData, dataStatementsFor } from './sql.mjs';
import { buildStats } from './stats.mjs';

export const WORKSPACES = [
  { key: 'operations', name: 'Arlet — Operations', links_mounts: true },
  { key: 'finance', name: 'Arlet — Finance review', links_mounts: false },
];

function jsonl(docs) {
  return docs.map((d) => JSON.stringify(d)).join('\n') + '\n';
}

function json(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

export function dataStatements(dataset) {
  return dataStatementsFor(dataset.tables);
}

export function renderFiles(dataset) {
  return {
    'activity.interactions.jsonl': jsonl(dataset.interactions),
    'activity.library.jsonl': jsonl(dataset.library),
    [dataset.spike ? 'crm.data.spike.sql' : 'crm.data.sql']: renderData(dataset.args, dataset.tables),
    'crm.schema.sql': renderSchema(dataset.args),
    'pages.json': json({ workspaces: WORKSPACES, pages: dataset.pages }),
    'stats.json': json(buildStats(dataset)),
  };
}
