// Authored, fictional organisations and name pools for Arlet Équipement's world (PLAN §5.2).
// Caveat: the company names were invented and checked against nothing. A same-named business
// may exist somewhere; none is meant, and none is a known Lyon institution or a brand.

// [name, kind, segment, city, postcode]. Index 0 is Arlet itself; Hôtel Varenne is the first
// client because the hub logic weights it as the largest account.
export const COMPANIES = [
  ['Arlet Équipement', 'self', 'distributor', 'Vénissieux', '69200'],
  ['Hôtel Varenne', 'client', 'hotel', 'Lyon 2e', '69002'],
  ['Bouchon Gaspard', 'client', 'restaurant', 'Lyon 5e', '69005'],
  ['Traiteur Mellot', 'client', 'caterer', 'Villeurbanne', '69100'],
  ['Le Comptoir Sablon', 'client', 'restaurant', 'Lyon 7e', '69007'],
  ['Hôtel des Canuts', 'client', 'hotel', 'Lyon 4e', '69004'],
  ['Brasserie Aubépine', 'client', 'restaurant', 'Lyon 6e', '69006'],
  ['Cuisine Centrale Saint-Fons', 'client', 'collective_catering', 'Saint-Fons', '69190'],
  ['Maison Rivoire Traiteur', 'client', 'caterer', 'Écully', '69130'],
  ['La Table de Clémence', 'client', 'restaurant', 'Lyon 1er', '69001'],
  ['Boulangerie Fournel', 'client', 'bakery', 'Caluire-et-Cuire', '69300'],
  ['Résidence Les Tilleuls', 'client', 'collective_catering', 'Tassin-la-Demi-Lune', '69160'],
  ['Hôtel Perrache Rive', 'client', 'hotel', 'Lyon 2e', '69002'],
  ['Le Petit Mâchon', 'client', 'restaurant', 'Lyon 9e', '69009'],
  ['Ateliers Gourmets Monplaisir', 'client', 'caterer', 'Lyon 8e', '69008'],
  ['Pizzeria Calvi', 'client', 'restaurant', 'Oullins', '69600'],
  ['Collège Jean-Moulinet', 'client', 'collective_catering', 'Bron', '69500'],
  ['Bistrot du Quai Rambert', 'client', 'restaurant', 'Lyon 9e', '69009'],
  ['Hôtel Les Brotteaux', 'client', 'hotel', 'Lyon 6e', '69006'],
  ['Pâtisserie Lagarde', 'client', 'bakery', 'Lyon 3e', '69003'],
  ['Clinique du Parc Bellecombe', 'client', 'collective_catering', 'Lyon 6e', '69006'],
  ['Le Zinc Croix-Rousse', 'client', 'bar', 'Lyon 4e', '69004'],
  ['Restaurant Ostrea', 'client', 'restaurant', 'Lyon 2e', '69002'],
  ['Traiteur des Monts d’Or', 'client', 'caterer', 'Limonest', '69760'],
  ['Hôtel Saône Lumière', 'client', 'hotel', 'Neuville-sur-Saône', '69250'],
  ['Cantine Gerland Campus', 'client', 'collective_catering', 'Lyon 7e', '69007'],
  ['Le Relais de Vienne', 'client', 'restaurant', 'Vienne', '38200'],
  ['Boulangerie Barrault', 'client', 'bakery', 'Villefranche-sur-Saône', '69400'],
  ['Brasserie Part-Dieu Central', 'client', 'restaurant', 'Lyon 3e', '69003'],
  ['Ehpad Les Glycines', 'client', 'collective_catering', 'Meyzieu', '69330'],
  ['Le Comptoir des Halles Neuves', 'client', 'restaurant', 'Lyon 3e', '69003'],
  ['Hôtel Vaise Gare', 'client', 'hotel', 'Lyon 9e', '69009'],
  ['Cave et Cuisine Sainte-Foy', 'client', 'restaurant', 'Sainte-Foy-lès-Lyon', '69110'],
  ['Bar à Vins Le Tire-Bouchon', 'client', 'bar', 'Lyon 1er', '69001'],
  ['Restauration Scolaire Givors', 'client', 'collective_catering', 'Givors', '69700'],
  ['Le Jardin de Fourvière', 'client', 'restaurant', 'Lyon 5e', '69005'],
  ['Saint-Priest Événements Traiteur', 'client', 'caterer', 'Saint-Priest', '69800'],
  ['Hôtel Domaine de Charbonnières', 'client', 'hotel', 'Charbonnières-les-Bains', '69260'],
  ['Crêperie Ty Rhône', 'client', 'restaurant', 'Lyon 7e', '69007'],
  ['Frigeco Industrie', 'supplier', 'refrigeration_maker', 'Saint-Étienne', '42000'],
  ['Nordval Froid', 'supplier', 'refrigeration_maker', 'Annecy', '74000'],
  ['Fourneaux Delaire', 'supplier', 'cooking_maker', 'Roanne', '42300'],
  ['Lavéo Systèmes', 'supplier', 'dishwashing_maker', 'Grenoble', '38000'],
  ['Inoxa Mobilier', 'supplier', 'stainless_maker', 'Bourgoin-Jallieu', '38300'],
  ['Ventarel', 'supplier', 'ventilation_maker', 'Mâcon', '71000'],
  ['Préparia', 'supplier', 'preparation_maker', 'Clermont-Ferrand', '63000'],
  ['Batterie Morvan', 'supplier', 'smallwares_wholesaler', 'Chalon-sur-Saône', '71100'],
  ['Pièces Rapides Belcourt', 'supplier', 'spare_parts_wholesaler', 'Villeurbanne', '69100'],
  ['Hygiale', 'supplier', 'consumables_wholesaler', 'Valence', '26000'],
  ['SCI Quai Gerland', 'partner', 'landlord', 'Lyon 7e', '69007'],
  ['Rhodanie Énergie', 'partner', 'utilities', 'Lyon 3e', '69003'],
  ['Flottelia Location', 'partner', 'vehicle_lease', 'Vénissieux', '69200'],
  ['Mutuelle Pradel Assurances', 'partner', 'insurance', 'Lyon 2e', '69002'],
  ['Néotrame Informatique', 'partner', 'it_services', 'Villeurbanne', '69100'],
  ['Atelier Brume Communication', 'partner', 'marketing_agency', 'Lyon 1er', '69001'],
  ['Institut Saône Management', 'partner', 'business_school', 'Écully', '69130'],
  ['Transports Vercors Fret', 'partner', 'freight', 'Corbas', '69960'],
  ['Cabinet Vauclair Expertise', 'partner', 'accounting', 'Lyon 6e', '69006'],
  ['Garage Monplaisir Utilitaires', 'partner', 'garage', 'Lyon 8e', '69008'],
  ['Agence Voyages Ainay', 'partner', 'travel_agency', 'Lyon 2e', '69002'],
];

// Named people the story needs: [first, last, company name, job title, department].
export const NAMED_PEOPLE = [
  ['Inès', 'Caradec', 'Arlet Équipement', 'Operations director', 'management'],
  ['Jules', 'Marchand', 'Arlet Équipement', 'Finance controller', 'finance'],
  ['Hélène', 'Arlet', 'Arlet Équipement', 'Managing director', 'management'],
  ['Marc', 'Delorme', 'Hôtel Varenne', 'Head of purchasing', null],
  ['Sophie', 'Lambertin', 'Hôtel Varenne', 'Executive chef', null],
  ['Thierry', 'Gauvain', 'Frigeco Industrie', 'Key account manager', null],
  ['Camille', 'Royer', 'Nordval Froid', 'Sales engineer', null],
  ['Agnès', 'Pellerin', 'Institut Saône Management', 'Programme director', null],
];

export const FIRST_NAMES = [
  'Adrien', 'Alice', 'Amandine', 'Antoine', 'Arnaud', 'Aurélie', 'Baptiste', 'Bérénice', 'Bruno',
  'Capucine', 'Cédric', 'Chloé', 'Claire', 'Clément', 'Damien', 'Delphine', 'Élodie', 'Émile',
  'Estelle', 'Fabien', 'Florence', 'Gaëlle', 'Guillaume', 'Hugo', 'Isabelle', 'Jérôme', 'Joséphine',
  'Julien', 'Laetitia', 'Laurent', 'Léa', 'Lucas', 'Lucie', 'Manon', 'Mathieu', 'Mélanie', 'Nadia',
  'Nicolas', 'Noémie', 'Olivier', 'Pauline', 'Quentin', 'Rachid', 'Romain', 'Sandrine', 'Samir',
  'Sébastien', 'Solène', 'Sylvain', 'Tiphaine', 'Valentin', 'Véronique', 'Yann', 'Zoé',
];

export const LAST_NAMES = [
  'Allard', 'Barbier', 'Besson', 'Blanchon', 'Bonnefoy', 'Bouvard', 'Chabert', 'Chanel', 'Cordier',
  'Courtial', 'Dufresne', 'Duplantier', 'Escoffet', 'Faure', 'Ferrand', 'Gaillard', 'Garnier',
  'Giraudet', 'Guichard', 'Jacquemoud', 'Josserand', 'Lacroix', 'Laforge', 'Mallet', 'Martel',
  'Mathevon', 'Mercier', 'Monnet', 'Morel', 'Perrin', 'Peyrard', 'Poncet', 'Reynaud', 'Rivière',
  'Rolland', 'Rousset', 'Sauvignet', 'Tardy', 'Teyssier', 'Vachon', 'Vernay', 'Vial', 'Vincendon',
];

export const STAFF_TITLES = {
  sales: ['Sales representative', 'Key account manager', 'Inside sales', 'Sales assistant'],
  warehouse: ['Warehouse lead', 'Picker-packer', 'Delivery driver', 'Stock controller', 'Buyer'],
  finance: ['Accounts receivable', 'Accounts payable', 'Payroll and admin'],
  service: ['Field technician', 'Refrigeration technician', 'Service coordinator'],
};

// Arlet's 38 people: the named three plus this many per department.
export const STAFF_PER_DEPARTMENT = { sales: 10, warehouse: 11, finance: 4, service: 10 };

export const CLIENT_TITLES = {
  buyer: 'Purchasing manager', head_chef: 'Head chef', general_manager: 'General manager',
  accounts_payable: 'Accounts payable', technical_contact: 'Maintenance manager',
};
export const SUPPLIER_TITLES = {
  sales_rep: 'Area sales manager', logistics: 'Logistics coordinator',
  accounts_receivable: 'Credit controller', technical_support: 'Technical support engineer',
};
