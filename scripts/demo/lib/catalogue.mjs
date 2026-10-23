// Arlet's 120-product catalogue: authored base items, expanded into size/model variants.
// Prices are in integer cents so line totals round exactly as PostgreSQL's numeric does.

// category -> { supplier, stocked, lead, markup%, qty [min,max], items: [name, cost in euros] }
// Consumables are drop-shipped by their wholesaler, so they move no Arlet stock; of the smallwares,
// only the core range (the base variants) is kept on the shelf.
export const CATEGORIES = {
  cooking: {
    supplier: 'Fourneaux Delaire', stocked: false, lead: 18, markup: 32, qty: [1, 2],
    items: [['Six-burner gas range 900', 3900], ['Combi steam oven 10 GN 1/1', 7400],
      ['Induction hob 2 zones 7 kW', 2100], ['Salamander grill 600', 890], ['Tilting braising pan 80 L', 6200],
      ['Double fryer 2 x 10 L', 1350], ['Chargrill lava stone 800', 1650], ['Pasta cooker 40 L', 2300]],
  },
  refrigeration: {
    supplier: 'Frigeco Industrie', second: 'Nordval Froid', stocked: true, lead: 21, markup: 34, qty: [1, 2],
    items: [['Upright fridge 700 L GN 2/1', 1450], ['Undercounter fridge 3 doors', 1690],
      ['Blast chiller 5 levels', 3900], ['Upright freezer 700 L', 1580], ['Saladette counter 1365', 1240],
      ['Bottle cooler 2 doors', 980], ['Ice cube maker 46 kg', 1290], ['Pastry display cabinet', 3100]],
  },
  dishwashing: {
    supplier: 'Lavéo Systèmes', stocked: false, lead: 15, markup: 30, qty: [1, 1],
    items: [['Hood-type dishwasher 500', 4200], ['Undercounter glasswasher 400', 1450],
      ['Pot washer 700', 6100], ['Water softener 12 L', 310], ['Prewash spray unit', 420]],
  },
  preparation: {
    supplier: 'Préparia', stocked: true, lead: 12, markup: 36, qty: [1, 2],
    items: [['Planetary mixer 20 L', 1850], ['Vegetable cutter 550 kg/h', 1290], ['Vacuum packer 42 cm', 1680],
      ['Meat slicer 300', 840], ['Stick blender 450 mm', 290], ['Cutter mixer 5 L', 1150]],
  },
  ventilation: {
    supplier: 'Ventarel', stocked: false, lead: 25, markup: 28, qty: [1, 1],
    items: [['Wall extraction hood 2 m', 2400], ['Island extraction hood 3 m', 4600],
      ['Extraction fan 4000 m3/h', 1350], ['Grease filter set', 180]],
  },
  stainless_furniture: {
    supplier: 'Inoxa Mobilier', stocked: false, lead: 20, markup: 35, qty: [1, 3],
    items: [['Work table 1400 x 700', 340], ['Wall shelf 1200', 120], ['Sink unit 2 bowls', 690],
      ['Mobile rack 20 levels', 410], ['Hand-wash basin, knee-operated', 260]],
  },
  smallwares: {
    supplier: 'Batterie Morvan', stocked: 'core', lead: 7, markup: 45, qty: [2, 24],
    items: [['Gastronorm pan 1/1 x 65', 22], ['Chef knife 25 cm', 48], ['Stockpot 50 L', 115],
      ['Sauté pan 32 cm', 64], ['Chopping board HACCP blue', 19], ['Sheet pan 600 x 400', 17],
      ['Ladle 25 cl', 9], ['Polypropylene storage box 10 L', 14]],
  },
  consumables: {
    supplier: 'Hygiale', stocked: false, lead: 5, markup: 40, qty: [4, 40],
    items: [['Dishwasher detergent 20 L', 46], ['Rinse aid 10 L', 34], ['Descaler 5 L', 21],
      ['Vacuum bags 20 x 30 (100)', 12], ['Oven cleaner 5 L', 26], ['Food-safe sanitiser 5 L', 19]],
  },
  spare_parts: {
    supplier: 'Pièces Rapides Belcourt', stocked: true, lead: 6, markup: 50, qty: [1, 6],
    items: [['Door gasket 700 L', 58], ['Thermostat 30-110 °C', 44], ['Wash arm assembly', 96],
      ['Gas safety valve', 72], ['Fan motor 10 W', 39], ['Heating element 2.5 kW', 84],
      ['Solenoid valve', 51], ['Compressor relay kit', 66]],
  },
};

// Variants turn the 58 base items into exactly 120 products without inventing new item types.
const VARIANTS = ['', ' — Pro', ' — Compact', ' — XL'];

export function catalogueEntries() {
  const entries = [];
  const bases = Object.entries(CATEGORIES).flatMap(([category, spec]) =>
    spec.items.map(([name, cost]) => ({ category, name, cost })));
  for (let round = 0; entries.length < 120; round += 1) {
    for (const base of bases) {
      if (entries.length >= 120) break;
      if (round > 0 && (bases.indexOf(base) + round) % 2 === 1) continue;
      const factor = [100, 118, 86, 135][round % 4];
      entries.push({
        category: base.category,
        name: `${base.name}${VARIANTS[round % 4]}`,
        costCents: Math.round(base.cost * factor),
        core: round === 0,
      });
    }
  }
  return entries;
}
