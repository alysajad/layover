// Pure request/response mapping, exercised without credentials in Node tests.
export function providerUrl(input: any, key: string): URL {
  const point = (p: any) => {
    if (!Array.isArray(p) || p.length !== 2 || !p.every(Number.isFinite) || Math.abs(p[0]) > 180 || Math.abs(p[1]) > 85) throw Error('Invalid coordinate');
    return p as number[];
  };
  if (input.action === 'search') {
    if (typeof input.text !== 'string' || input.text.trim().length < 2 || input.text.length > 160) throw Error('Enter an area name');
    const url = new URL('https://api.geoapify.com/v1/geocode/search');
    url.search = new URLSearchParams({text:input.text.trim(),limit:'5',apiKey:key}).toString();
    return url;
  }
  if (input.action === 'highlight') {
    const match = typeof input.wikipedia === 'string' && input.wikipedia.match(/^([a-z]{2,3}(?:-[a-z]{2,8})?):([^|#\n]{1,200})$/);
    if (!match) throw Error('Invalid article');
    return new URL(`https://${match[1]}.wikipedia.org/api/rest_v1/page/summary/${encodeURIComponent(match[2])}`);
  }
  if (input.action === 'places') {
    const z = input.zone;
    let filter: string;
    if (z?.type === 'circle') {
      const [lon,lat] = point(z.center);
      if (!Number.isFinite(z.radius_m) || z.radius_m < 100 || z.radius_m > 30000) throw Error('Invalid radius');
      filter = `circle:${lon},${lat},${z.radius_m}`;
    } else if (z?.type === 'polygon') {
      if (!Array.isArray(z.vertices) || z.vertices.length < 3 || z.vertices.length > 20) throw Error('Invalid polygon');
      const vertices = z.vertices.map(point);
      const xs = vertices.map((p: number[])=>p[0]), ys = vertices.map((p: number[])=>p[1]);
      if (Math.max(...xs)-Math.min(...xs)>1 || Math.max(...ys)-Math.min(...ys)>1) throw Error('Polygon too large');
      filter = `rect:${Math.min(...xs)},${Math.min(...ys)},${Math.max(...xs)},${Math.max(...ys)}`;
    } else throw Error('Invalid zone');
    const categories: Record<string,string> = {all:'tourism,entertainment,natural,catering,public_transport,service',culture:'tourism,entertainment.culture',nature:'natural,leisure.park',food:'catering.restaurant,catering.food_court,catering.fast_food,catering.cafe',transport:'public_transport,rental.bicycle,rental.car,rental.boat,service.taxi',services:'service,commercial.supermarket,healthcare.pharmacy'};
    if (!categories[input.category]) throw Error('Invalid category');
    const url = new URL('https://api.geoapify.com/v2/places');
    url.search = new URLSearchParams({filter,categories:categories[input.category],limit:'40',apiKey:key}).toString();
    return url;
  }
  if (input.action !== 'route' || !['walk','bicycle','drive'].includes(input.mode) || !['balanced','short'].includes(input.path_kind)) throw Error('Unsupported route');
  if (!Array.isArray(input.points) || input.points.length < 2 || input.points.length > 10) throw Error('Choose 2–10 route points');
  const pts=input.points.map(point);
  if(pts.some((p:number[])=>Math.abs(p[0]-pts[0][0])>2 || Math.abs(p[1]-pts[0][1])>2)) throw Error('Route area too large');
  const url = new URL('https://api.geoapify.com/v1/routing');
  url.search = new URLSearchParams({waypoints:pts.map((p:number[])=>`${p[1]},${p[0]}`).join('|'),mode:input.mode,type:input.path_kind,format:'geojson',apiKey:key}).toString();
  return url;
}

export function normalize(input: any, body: any, checkedAt: string) {
  const text = (v: any, max=400): string | null => typeof v === 'string' && v.trim() ? v.trim().slice(0,max) : null;
  const link = (v: any): string | null => {
    try { const u=new URL(v); return ['https:','http:'].includes(u.protocol) && !u.username && !u.password ? u.href : null; } catch { return null; }
  };
  if (input.action === 'highlight') return {
    description:text(body.extract,1200), source:'Wikipedia · CC BY-SA',
    source_url:link(body.content_urls?.desktop?.page), source_checked_at:checkedAt,
  };
  if (!Array.isArray(body.features)) throw Error('Invalid provider response');
  if (input.action === 'search') return {results:body.features.slice(0,5).flatMap((f:any)=> {
    const p=f.properties;
    return p && Number.isFinite(p.lon) && Number.isFinite(p.lat) ? [{name:text(p.formatted ?? p.name,240),point:[p.lon,p.lat]}] : [];
  })};
  if (input.action === 'places') return {places:body.features.slice(0,40).flatMap((f:any)=> {
    const p=f.properties;
    if(!p || typeof p.place_id!=='string' || !Number.isFinite(p.lon) || !Number.isFinite(p.lat)) return [];
    const raw=p.datasource?.raw ?? {}, cats=Array.isArray(p.categories) ? p.categories.filter((c:any)=>typeof c==='string') : [];
    const kind=cats.some((c:string)=>c.startsWith('public_transport') || ['rental.bicycle','rental.car','rental.boat','service.taxi'].includes(c)) ? 'transport'
      : cats.some((c:string)=>c.startsWith('catering')) ? 'food'
      : cats.some((c:string)=>c.startsWith('service') || c.startsWith('commercial') || c.startsWith('healthcare')) ? 'services'
      : cats.some((c:string)=>c.startsWith('natural') || c.startsWith('leisure.park')) ? 'nature' : 'culture';
    const specific=[...cats].sort((a:string,b:string)=>b.length-a.length)[0] ?? 'tourism';
    const cuisine=Array.isArray(p.catering?.cuisine) ? p.catering.cuisine.join(', ') : raw.cuisine;
    // An explicit OSM fee=no describes admission only, never a meal or bus fare.
    const free=['culture','nature'].includes(kind) && raw.fee==='no';
    const osmType=raw.osm_type ?? p.datasource?.osm_type, osmId=raw.osm_id ?? p.datasource?.osm_id;
    const osm= ['node','way','relation'].includes(osmType) && /^\d+$/.test(String(osmId)) ? `https://www.openstreetmap.org/${osmType}/${osmId}`
      : `https://www.openstreetmap.org/?mlat=${p.lat}&mlon=${p.lon}#map=18/${p.lat}/${p.lon}`;
    return [{id:p.place_id,provider:'geoapify',provider_place_id:p.place_id,name:String(p.name ?? p.formatted ?? 'Unnamed place').slice(0,160),
      category:specific,kind,point:[p.lon,p.lat],source_checked_at:checkedAt,
      address:text(p.address_line2 ?? p.formatted),description:text(raw.description ?? raw['description:en']),
      cuisine:text(cuisine),opening_hours:text(p.opening_hours ?? raw.opening_hours),
      website:link(p.website ?? p.contact?.website ?? raw.website),wikipedia:text(p.wiki_and_media?.wikipedia ?? raw.wikipedia,215),
      operator:text(p.operator ?? raw.operator), network:text(raw.network), fee:text(raw.fee,80),free_admission:free,
      source_url:osm, selection_type:'excluded',priority:1,dwell_minutes:kind==='transport'?5:30,source:'Geoapify / OpenStreetMap'}];
  })};
  return {routes:body.features.slice(0,1).map((f:any)=> {
    const p=f.properties;
    if(!Array.isArray(p?.legs) || p.legs.length!==input.points.length-1 ||
      p.legs.some((l:any)=>!Number.isFinite(l.time) || l.time<0 || !Number.isFinite(l.distance) || l.distance<0) ||
      !['MultiLineString','LineString'].includes(f.geometry?.type)) throw Error('Incomplete route response');
    return {provider:'geoapify',checked_at:checkedAt,path_kind:input.path_kind,geometry:f.geometry,toll:p.toll===true,ferry:p.ferry===true,
      legs:p.legs.map((l:any,i:number)=>({leg_order:i,origin:input.points[i],destination:input.points[i+1],
        transport_mode:input.mode,distance_m:l.distance,duration_seconds:Math.ceil(l.time),source:'Geoapify',checked_at:checkedAt}))};
  })};
}
