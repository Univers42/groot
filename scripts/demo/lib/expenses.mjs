// Arlet's operating expenses: a monthly schedule per category, each paid to a partner or
// supplier and approved by a named person, so every expense row links to two records.
import { idFor } from './uuid.mjs';
import { forkRng, addDays, addMonths } from './prng.mjs';

// category -> [payee, department, per month, [min, max] euros, description]
const SCHEDULE = {
  rent: ['SCI Quai Gerland', 'warehouse', 1, [6800, 6800], 'Warehouse and showroom rent, Vénissieux'],
  utilities: ['Rhodanie Énergie', 'warehouse', 2, [380, 1450], 'Electricity and water, warehouse'],
  vehicle_lease: ['Flottelia Location', 'service', 1, [3900, 3900], 'Lease, 9 service vans and 2 delivery trucks'],
  fuel: ['Flottelia Location', 'service', 9, [70, 260], 'Fuel card statement'],
  vehicle_maintenance: ['Garage Monplaisir Utilitaires', 'service', 2, [180, 1300], 'Van servicing and tyres'],
  insurance: ['Mutuelle Pradel Assurances', 'finance', 1, [1150, 1150], 'Fleet and premises insurance'],
  it: ['Néotrame Informatique', 'finance', 2, [240, 1900], 'ERP licence, laptops and support'],
  marketing: ['Atelier Brume Communication', 'sales', 1, [450, 3200], 'Showroom events and catalogue print'],
  travel: ['Agence Voyages Ainay', 'sales', 2, [120, 900], 'Trade fair and supplier visits'],
  freight: ['Transports Vercors Fret', 'warehouse', 8, [90, 780], 'Palletised deliveries, Rhône and Isère'],
  professional_fees: ['Cabinet Vauclair Expertise', 'finance', 1, [900, 2600], 'Accounting and payroll services'],
  training: ['Institut Saône Management', 'service', 1, [350, 1400], 'Refrigerant handling certification'],
};

// Inès's executive certificate, paid in four instalments: the trade side of the academy notes.
const TUITION_INSTALMENTS = 4;
const TUITION_CENTS = 425000;

export function buildExpenses({ seed, anchor }, idx, start) {
  const rng = forkRng(seed, 'expenses');
  const rows = [];
  const add = (day, category, department, payee, approver, description, cents) => {
    rows.push({
      id: idFor('trade_expenses', `${category}:${rows.length}`), spent_on: day, category, department,
      payee_company_id: idx.companyByName.get(payee).id, approved_by_id: approver.id, description, amount_eur: cents,
    });
  };
  for (let month = 0; month < 18; month += 1) {
    const first = addMonths(start, month);
    for (const [category, [payee, department, perMonth, [min, max], description]] of Object.entries(SCHEDULE)) {
      for (let n = 0; n < perMonth; n += 1) {
        const day = addDays(first, n === 0 && perMonth === 1 ? 4 : rng.int(0, 27));
        if (day >= anchor) continue;
        const cents = min === max ? min * 100 : rng.int(min * 100, max * 100);
        const approver = cents > 300000 ? idx.people.helene : idx.people.jules;
        add(day, category, department, payee, approver, description, cents);
      }
    }
  }
  for (let n = 0; n < TUITION_INSTALMENTS; n += 1) {
    const day = addMonths(start, 3 + n * 3);
    if (day >= anchor) continue;
    add(day, 'training', 'management', 'Institut Saône Management', idx.people.helene,
      `Executive certificate in operations management, instalment ${n + 1}/${TUITION_INSTALMENTS} (I. Caradec)`, TUITION_CENTS);
  }
  rows.sort((a, b) => (a.spent_on < b.spent_on ? -1 : a.spent_on > b.spent_on ? 1 : 0));
  return rows;
}
