import { createClient } from 'npm:@supabase/supabase-js@2';
import { normalize, providerUrl } from './provider.ts';

const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
const reply = (body: unknown,status=200) => Response.json(body,{status,headers:cors});

Deno.serve(async request => {
  if(request.method==='OPTIONS') return new Response('ok',{headers:cors});
  if(request.method!=='POST') return reply({error:'Use POST'},405);
  const authorization=request.headers.get('Authorization');
  if(!authorization?.startsWith('Bearer ')) return reply({error:'Sign in to explore'},401);
  const db=createClient(Deno.env.get('SUPABASE_URL')!,Deno.env.get('SUPABASE_ANON_KEY')!,{global:{headers:{Authorization:authorization}}});
  const {data:{user},error:authError}=await db.auth.getUser();
  if(authError || !user) return reply({error:'Sign in to explore'},401);
  try {
    const text=await request.text();
    if(text.length>12000) return reply({error:'Request too large'},400);
    const input=JSON.parse(text);
    let url:URL;
    try { url=providerUrl(input,Deno.env.get('GEOAPIFY_API_KEY') ?? ''); }
    catch { return reply({error:'Invalid area, category or route parameters'},400); }
    const {error}=await db.rpc('explorer_provider_access',{p_trip_id:input.trip_id});
    if(error) return reply({error:error.message.includes('rate limit')?'Too many requests. Retry in a minute.':'Trip organizer access required'},error.message.includes('rate limit')?429:403);
    if(input.action!=='highlight' && !Deno.env.get('GEOAPIFY_API_KEY')) return reply({error:'Place and route service is not configured'},503);
    // Balance discovery across interests; a dense restaurant district should not hide bus stops.
    if(input.action==='places' && input.category==='all') {
      const results=await Promise.allSettled(['culture','nature','food','transport','services'].map(async category=> {
        const query={...input,category};
        const endpoint=providerUrl(query,Deno.env.get('GEOAPIFY_API_KEY')!);
        endpoint.searchParams.set('limit','8');
        const response=await fetch(endpoint,{signal:AbortSignal.timeout(15000)});
        if(!response.ok) throw {category,status:response.status};
        return normalize(query,await response.json(),new Date().toISOString());
      }));
      if(results.every(r=>r.status==='rejected')) return reply({error:'Place service unavailable. Retry later.'},results.some(r=>r.status==='rejected' && r.reason?.status===429)?429:502);
      const places=new Map();
      for(const r of results) if(r.status==='fulfilled') for(const p of r.value.places ?? []) places.set(p.id,p);
      const missing=results.flatMap((r,i)=>r.status==='rejected'?[['culture','nature','food','transport','services'][i]]:[]);
      return reply({places:[...places.values()].slice(0,40),...(missing.length?{warning:`Some categories could not load: ${missing.join(', ')}. Retry that category.`}:{})});
    }
    const response=await fetch(url,{signal:AbortSignal.timeout(15000)});
    if(!response.ok) return reply({error:response.status===429?'Provider rate limit. Retry later.':'Provider unavailable. Try another mode or area.'},response.status===429?429:502);
    return reply(normalize(input,await response.json(),new Date().toISOString()));
  } catch { return reply({error:'Provider request failed. Retry later.'},502); }
});
