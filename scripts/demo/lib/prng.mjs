// Seeded randomness and anchor-relative dates. Each dataset draws from its own stream
// (forkRng(seed, label)), so adding a field to one generator does not reshuffle the others.
import { createHash } from 'node:crypto';

// mulberry32: 32-bit state, enough period for a few hundred thousand draws, and reproducible
// on every JS engine because it only uses Math.imul and 32-bit shifts.
function mulberry32(state) {
  let a = state >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function forkRng(seed, label) {
  const digest = createHash('sha256').update(`${seed}:${label}`).digest();
  const next = mulberry32(digest.readUInt32LE(0));
  const rng = {
    next,
    int: (min, max) => min + Math.floor(next() * (max - min + 1)),
    chance: (p) => next() < p,
    pick: (list) => list[Math.floor(next() * list.length)],
    weighted(list, weightOf) {
      const total = list.reduce((sum, item) => sum + weightOf(item), 0);
      let roll = next() * total;
      for (const item of list) {
        roll -= weightOf(item);
        if (roll < 0) return item;
      }
      return list[list.length - 1];
    },
    sample(list, count) {
      const pool = [...list];
      const out = [];
      while (out.length < count && pool.length > 0) out.push(pool.splice(Math.floor(next() * pool.length), 1)[0]);
      return out;
    },
    // Caveat: Knuth's method is O(mean) per draw; fine for the small daily means used here,
    // slow and float-inexact above a mean of a few hundred.
    poisson(mean) {
      const limit = Math.exp(-mean);
      let k = 0;
      let p = next();
      while (p > limit) {
        k += 1;
        p *= next();
      }
      return k;
    },
  };
  return rng;
}

const DAY_MS = 86400000;

export function parseDay(text) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
  if (!m) return null;
  const ms = Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
  return formatDay(ms) === text ? ms : null;
}

export function formatDay(ms) {
  return new Date(ms).toISOString().slice(0, 10);
}

export function addDays(day, n) {
  return formatDay(parseDay(day) + n * DAY_MS);
}

export function daysBetween(from, to) {
  return Math.round((parseDay(to) - parseDay(from)) / DAY_MS);
}

export function addMonths(day, n) {
  const d = new Date(parseDay(day));
  const target = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + n, 1));
  const last = new Date(Date.UTC(target.getUTCFullYear(), target.getUTCMonth() + 1, 0)).getUTCDate();
  target.setUTCDate(Math.min(d.getUTCDate(), last));
  return formatDay(target.getTime());
}

export function isWeekday(day) {
  const dow = new Date(parseDay(day)).getUTCDay();
  return dow !== 0 && dow !== 6;
}

export function monthOf(day) {
  return day.slice(0, 7);
}

export function quarterOf(day) {
  return `${day.slice(0, 4)}-Q${Math.floor((Number(day.slice(5, 7)) - 1) / 3) + 1}`;
}

export function timestamp(day, minutes) {
  const hh = String(Math.floor(minutes / 60)).padStart(2, '0');
  const mm = String(minutes % 60).padStart(2, '0');
  return `${day}T${hh}:${mm}:00Z`;
}

export function slug(text) {
  return text.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

export function centsText(cents) {
  const sign = cents < 0 ? '-' : '';
  const abs = Math.abs(cents);
  return `${sign}${Math.floor(abs / 100)}.${String(abs % 100).padStart(2, '0')}`;
}
