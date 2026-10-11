// Pure planning/provider normalization, exercised without live API charges.
type Data = Record<string, any>;
const DAY = 86400000;
const integer = (v: unknown, low: number, high: number): number => {
  if (!Number.isSafeInteger(v) || (v as number) < low || (v as number) > high) throw new Error('Invalid planning amount or occupancy');
  return v as number;
};
export function safeLink(value: unknown): string | null {
  try {
    const u = new URL(String(value));
    return ['http:', 'https:'].includes(u.protocol) && !u.username && !u.password && !u.hostname.endsWith('serpapi.com') ? u.href : null;
  } catch { return null; }
}
function point(value: Data): number[] | null {
  const lat = value?.latitude, lon = value?.longitude;
  return typeof lat === 'number' && typeof lon === 'number' && Number.isFinite(lat) && Number.isFinite(lon)
    && Math.abs(lat) <= 85 && Math.abs(lon) <= 180 ? [lat, lon] : null;
}
function amount(value: unknown): number | null {
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return null;
  const minor = Math.ceil(value * 100 - 1e-7);
  return Number.isSafeInteger(minor) && minor < 1e12 ? minor : null;
}
function rating(v: unknown): number | null { return typeof v === 'number' && v >= 0 && v <= 5 ? Math.round(v * 10) / 10 : null; }
function reviews(v: unknown): number { return Number.isSafeInteger(v) && (v as number) >= 0 ? v as number : 0; }
const text = (v: unknown, n = 240) => typeof v === 'string' ? v.slice(0, n) : '';
const maps = (name: string) => `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(name)}`;
export function validateJob(job: Data, now = new Date()): Data {
  const c = job.context, s = job.settings;
  const start = Date.parse(c.start_date), end = Date.parse(c.end_date);
  const nights = (end - start) / DAY;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(c.start_date) || !/^\d{4}-\d{2}-\d{2}$/.test(c.end_date)
    || !Number.isInteger(nights) || nights < 0 || nights > 13 || c.start_date < now.toISOString().slice(0, 10)
    || typeof c.destination !== 'string' || !c.destination.trim() || c.destination.length > 240 || c.currency !== 'INR') {
    throw new Error('Set a destination and future dates, up to 14 days, with an INR pot.');
  }
  const group = integer(c.members.length, 1, 50);
  const rooms = integer(s.rooms, 1, 20), adults = integer(s.adults_per_room, 1, 4);
  if (rooms * adults < group) throw new Error('Room occupancy no longer covers the group. Update planning preferences.');
  integer(c.budget_minor, 1, 1e12);
  for (const k of ['food_daily_minor', 'transport_daily_minor', 'activity_daily_minor', 'journey_minor']) integer(s[k], 0, 1e9);
  if (!['walking', 'transit', 'driving'].includes(s.transport_mode)) throw new Error('Choose local transport.');
  return { ...c, ...s, group, nights, days: nights + 1 };
}
export function searchUrl(kind: string, x: Data, key: string): URL {
  const url = new URL('https://serpapi.com/search.json');
  const p: Record<string, string> = { api_key: key, hl: 'en' };
  if (kind === 'hotels') Object.assign(p, { engine: 'google_hotels', q: `Hotels in ${x.destination}`, currency: x.currency,
    check_in_date: x.start_date, check_out_date: x.end_date, adults: String(x.adults_per_room), children: '0' });
  else Object.assign(p, { engine: 'google_maps', type: 'search', q: `${kind === 'sights' ? 'tourist attractions' : kind === 'cafes' ? 'cafes' : `${text(x.food_preferences, 160)} local food restaurants`} in ${x.destination}` });
  url.search = new URLSearchParams(p).toString();
  return url;
}
export function hotels(raw: Data, x: Data): Data[] {
  // Never infer a stay total from an unspecified nightly rate or multiply rentals as rooms.
  if (raw.search_parameters?.currency !== x.currency || raw.search_parameters?.check_in_date !== x.start_date
    || raw.search_parameters?.check_out_date !== x.end_date || Number(raw.search_parameters?.adults) !== x.adults_per_room) {
    throw new Error('Hotel response did not match the requested dates, occupancy and currency.');
  }
  const found = (Array.isArray(raw.properties) ? raw.properties : raw.name ? [raw] : []).flatMap((h: Data) => {
    const cost = amount(h.total_rate?.extracted_lowest), p = point(h.gps_coordinates);
    if (h.type !== 'hotel' || !text(h.name) || cost === null || !p) return [];
    return [{ name: text(h.name), point: p, room_stay_minor: cost, total_minor: cost * x.rooms,
      rating: rating(h.overall_rating), reviews: reviews(h.reviews),
      url: safeLink(h.link) ?? `https://www.google.com/travel/hotels?q=${encodeURIComponent(`${h.name} ${x.destination} ${x.start_date} to ${x.end_date}`)}`,
      rooms: x.rooms, adults_per_room: x.adults_per_room, nights: x.nights,
      source: 'Google Hotels via SerpApi', quote_note: 'Listed stay rate × rooms. Room availability, taxes and final total must be confirmed with the seller.' }];
  });
  return found.filter((h: Data, i: number, all: Data[]) => all.findIndex(v => v.name === h.name) === i);
}
export function places(raw: Data, kind: string): Data[] {
  const found = (Array.isArray(raw.local_results) ? raw.local_results : []).flatMap((v: Data) => {
    const p = point(v.gps_coordinates);
    if (!text(v.title) || !p || v.permanently_closed === true || v.temporarily_closed === true) return [];
    return [{ name: text(v.title), point: p, kind, rating: rating(v.rating), reviews: reviews(v.reviews),
      address: text(v.address, 400), description: text(v.description, 400), cuisine: text(v.type, 120),
      price_label: text(v.price, 60), url: maps(`${v.title} ${text(v.address)}`), source: 'Google Maps via SerpApi' }];
  });
  return found.sort((a: Data, b: Data) => score(b) - score(a));
}
function score(v: Data): number { return v.rating === null ? 0 : v.rating * Math.min(1, Math.log10(v.reviews + 1) / 3); }
function distance(a: number[], b: number[]): number {
  const rad = Math.PI / 180;
  const v = Math.sin((b[0] - a[0]) * rad / 2) ** 2 + Math.cos(a[0] * rad) * Math.cos(b[0] * rad) * Math.sin((b[1] - a[1]) * rad / 2) ** 2;
  return 12742 * Math.asin(Math.min(1, Math.sqrt(v)));
}
export function weatherUrl(p: number[], apiKey?: string): URL {
  const u = new URL(apiKey ? 'https://customer-api.open-meteo.com/v1/forecast' : 'https://api.open-meteo.com/v1/forecast');
  u.search = new URLSearchParams({ latitude: String(p[0]), longitude: String(p[1]), timezone: 'auto', forecast_days: '16',
    daily: 'temperature_2m_max,temperature_2m_min,precipitation_probability_max', ...(apiKey ? { apikey: apiKey } : {}) }).toString();
  return u;
}
export function weatherDays(raw: Data, x: Data): Data[] {
  const d = raw?.daily;
  if (!Array.isArray(d?.time)) return [];
  return d.time.flatMap((date: string, i: number) => {
    const hi = d.temperature_2m_max?.[i], lo = d.temperature_2m_min?.[i], rain = d.precipitation_probability_max?.[i];
    return date >= x.start_date && date <= x.end_date && [hi, lo, rain].every(v => typeof v === 'number' && Number.isFinite(v))
      ? [{ date, high_c: hi, low_c: lo, rain_percent: rain }] : [];
  });
}
export function buildPlan(job: Data, inventory: Data, now = new Date()): Data {
  const x = validateJob(job, now), warnings: string[] = [...(inventory.warnings ?? [])];
  const reserve = Math.ceil(x.budget_minor / 10);
  const costs = { food: x.food_daily_minor * x.group * x.days, transport: x.transport_daily_minor * x.days,
    activities: x.activity_daily_minor * x.group * x.days, journey: x.journey_minor, reserve };
  const allowance = Object.values(costs).reduce((a, b) => a + b, 0);
  const stays: Data[] = x.nights === 0 ? [{ name: 'Day trip · no overnight stay', total_minor: 0, point: inventory.sights?.[0]?.point ?? inventory.food?.[0]?.point ?? inventory.cafes?.[0]?.point }]
    : inventory.hotels ?? [];
  const affordable = stays.filter(h => h.total_minor + allowance <= x.budget_minor)
    .sort((a, b) => score(b) - score(a) || a.total_minor - b.total_minor).slice(0, 3);
  if (!affordable.length) warnings.push(stays.length ? 'No stay fits after daily allowances and the 10% reserve. Adjust the pot, dates, rooms or allowances.'
    : 'No hotels returned a matching stay price. Try different dates or destination; no price has been invented.');
  const weather = inventory.weather ?? [];
  if (weather.length < x.days) warnings.push('Forecast is unavailable for some trip dates. Refresh nearer departure; packing includes itinerary-based essentials.');
  if (!x.origin) warnings.push('Travel to and from the destination is not routed. Add your departure city and allow for return travel.');
  warnings.push('Suggested times are flexible. Verify opening hours, menus, admission fees and transport schedules before booking.');
  const options = affordable.map((hotel, optionIndex) => {
    const entries: Data[] = [], days: Data[] = [];
    const add = (kind: string, key: string, title: string, details: Data) => entries.push({ kind, key, title: title.slice(0, 240), details });
    const nearby = (kind: string) => (inventory[kind] ?? []).filter((p: Data) => hotel.point && distance(hotel.point, p.point) <= 15);
    const sights = nearby('sights'), food = nearby('food'), cafes = nearby('cafes');
    const used = new Set<string>();
    if (x.nights) add('booking', 'hotel', hotel.name, { date: x.start_date, time: '', address: x.destination, url: hotel.url,
      notes: `${x.start_date} to ${x.end_date} · ${x.rooms} room(s), ${x.adults_per_room} adults per room · Listed group stay estimate INR ${(hotel.total_minor / 100).toFixed(2)}. ${hotel.quote_note}` });
    if (x.origin) add('booking', 'journey', `${x.origin} ↔ ${x.destination}`, { date: x.start_date, url: `https://www.google.com/maps/dir/?api=1&origin=${encodeURIComponent(x.origin)}&destination=${encodeURIComponent(x.destination)}&travelmode=transit`,
      notes: `Choose and book outward/return transport. Group return-travel allowance INR ${(x.journey_minor / 100).toFixed(2)}; fare and seats not checked.` });
    for (let d = 0; d < x.days; d++) {
      const date = new Date(Date.parse(x.start_date) + d * DAY).toISOString().slice(0, 10);
      const stops: Data[] = [];
      let previous = hotel.point;
      const choices: [string, Data[]][] = [['09:00', cafes], ['11:00', sights], ['13:00', food], ['16:00', sights], ['19:00', food]];
      for (const [time, pool] of choices) {
        const ranked = pool.filter(p => !used.has(p.name) || p.kind !== 'sights').sort((a, b) => {
          const aUsed = used.has(a.name) ? 10 : 0, bUsed = used.has(b.name) ? 10 : 0;
          return (distance(previous ?? a.point, a.point) + aUsed - score(a)) - (distance(previous ?? b.point, b.point) + bUsed - score(b));
        });
        const p = ranked[0];
        if (!p) {
          add('itinerary', `${date}/${time}`, time === '11:00' || time === '16:00' ? 'Free time to explore' : 'Meal break · choose locally',
            { date, time, notes: 'No additional nearby place matched. Keep this time flexible and use the daily allowance.' });
          stops.push({ time, name: 'Flexible time', url: null });
          continue;
        }
        const km = previous ? distance(previous, p.point) : 0;
        const mode = km <= 1 ? 'walking' : x.transport_mode;
        const route = `https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(p.point.join(','))}&travelmode=${mode}${previous ? `&origin=${encodeURIComponent(previous.join(','))}` : ''}`;
        const review = p.rating === null ? 'Rating unavailable' : `${p.rating}/5 · ${p.reviews} reviews`;
        const note = `${review}. ${p.description || p.cuisine || ''} ${mode === 'transit' ? 'Check public transport' : mode === 'driving' ? 'Drive or take a cab' : 'Walk'}; check route and opening hours. ${p.kind === 'sights' ? 'Admission' : 'Meals'} use the daily allowance; exact price unverified.`;
        add('itinerary', `${date}/${time}`, p.name, { date, time, address: p.address, url: p.url, notes: note, directions_url: route });
        if (p.kind === 'sights') add('booking', `tickets/${date}/${time}`, `Check tickets: ${p.name}`, { date, time, address: p.address, url: p.url,
          notes: 'Check whether admission needs a ticket or advance reservation. Price is not quoted; use the activity allowance. Record the confirmation after booking.' });
        stops.push({ ...p, time, mode, directions_url: route });
        used.add(p.name); previous = p.point;
      }
      days.push({ date, stops, weather: weather.find((w: Data) => w.date === date) ?? null });
    }
    const packing = [
      ['documents', 'Pack ID and booking confirmations', 'Needed for hotel check-in and booked journeys.'],
      ['shoes', 'Pack comfortable walking shoes', 'The daily plan includes sightseeing and short walks.'],
      ['power', 'Pack a charger and power bank', 'Keep booking links and directions accessible.'],
      ['water', 'Carry a refillable water bottle', 'For the planned sightseeing days.'],
    ];
    if (weather.some((w: Data) => w.rain_percent >= 40)) packing.push(['rain', 'Pack an umbrella or rain jacket', 'Rain is possible on the forecasted trip dates.']);
    if (weather.some((w: Data) => w.high_c >= 28)) packing.push(['sun', 'Pack sun protection and light clothing', 'Warm temperatures are forecast during the trip.']);
    if (weather.some((w: Data) => w.low_c <= 15)) packing.push(['layers', 'Pack a warm layer', 'Cool temperatures are forecast during the trip.']);
    for (const [key, title, notes] of packing) add('task', `packing/${key}`, title, { notes, done: false });
    add('task', 'verify', 'Confirm opening hours, fares and dietary needs', { notes: 'Check linked listings before departure. Meal and admission amounts are allowances, not quoted prices.', done: false });
    add('task', 'weather', 'Check weather again before departure', { notes: `Forecast checked ${now.toISOString().slice(0, 10)} via Open-Meteo. ${weather.length}/${x.days} trip dates covered.`, done: false });
    if (x.nights) add('task', 'reserve', 'Book the stay and record the confirmation', { notes: 'Open Bookings, confirm rooms and final price with the seller, then add the booking reference. Record actual payments in Expenses.', done: false });
    const total = hotel.total_minor + allowance;
    return { title: `Option ${optionIndex + 1} · ${hotel.name}`, hotel, total_minor: total, remaining_minor: x.budget_minor - total,
      costs: { stay: hotel.total_minor, ...costs }, days, entries,
      summary: `${x.destination} · ${x.start_date} to ${x.end_date} · ${x.group} travelers.\n${hotel.name}\nPlanned total INR ${(total / 100).toFixed(2)}, including allowances and 10% reserve. Prices need seller confirmation.\n${days.map(d => `${d.date}: ${d.stops.map((p: Data) => `${p.time} ${p.name}`).join(' → ')}`).join('\n')}\nDaily details are in Plan; booking links in Bookings; packing and tasks in Group.` };
  });
  return { options, warnings, checked_at: now.toISOString(), source: 'Google Hotels / Google Maps via SerpApi; Open-Meteo forecast',
    occupancy_note: `${x.group} travelers; ${x.rooms} rooms at ${x.adults_per_room} adults each. Children and special room requirements must be checked with the seller.`,
    budget_minor: x.budget_minor, currency: x.currency };
}

export async function generate(job: Data, key: string, weatherKey?: string, fetcher: typeof fetch = fetch): Promise<Data> {
  const x = validateJob(job);
  if (!key) throw new Error('Live prices are not configured. Set SERPAPI_API_KEY in the planner function secrets.');
  async function get(url: URL): Promise<Data> {
    const response = await fetcher(url, { signal: AbortSignal.timeout(25000) });
    if (!response.ok) throw new Error('A travel data provider is unavailable or out of credits. Retry after checking provider access.');
    const raw = await response.json();
    if (raw.error) throw new Error('The travel provider could not complete this search. Check provider access or change trip dates.');
    return raw;
  }
  const kinds = x.nights ? ['hotels', 'sights', 'food', 'cafes'] : ['sights', 'food', 'cafes'];
  const results = await Promise.allSettled(kinds.map(kind => get(searchUrl(kind, x, key))));
  const inventory: Data = { warnings: [] };
  results.forEach((r, i) => {
    const kind = kinds[i];
    if (r.status === 'rejected') {
      if (kind === 'hotels') throw r.reason;
      inventory.warnings.push(`${kind} search unavailable; some time slots will remain flexible.`); inventory[kind] = [];
    } else inventory[kind] = kind === 'hotels' ? hotels(r.value, x) : places(r.value, kind);
  });
  if (!['sights','food','cafes'].some(k => inventory[k]?.length)) throw new Error('No usable place results were returned. Try a more specific destination.');
  const p = inventory.hotels?.[0]?.point ?? inventory.sights?.[0]?.point ?? inventory.food?.[0]?.point ?? inventory.cafes?.[0]?.point;
  if (p) {
    try { inventory.weather = weatherDays(await get(weatherUrl(p, weatherKey)), x); }
    catch { inventory.warnings.push('Weather service unavailable. Refresh the forecast before departure.'); }
  }
  return buildPlan(job, inventory);
}
