import { createClient } from 'npm:@supabase/supabase-js@2';
import { generate } from './planner.ts';
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const reply = (body: unknown, status = 200) => Response.json(body, { status, headers: cors });
  if (request.method !== 'POST') return reply({ error: 'POST required' }, 405);
  const url = Deno.env.get('SUPABASE_URL')!;
  const secret = Deno.env.get('PLANNER_SECRET');
  const scheduled = !!secret && request.headers.get('x-planner-secret') === secret;
  let tripId: string | null = null;
  try {
    if (!scheduled) {
      const auth = request.headers.get('Authorization') ?? '';
      const user = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { global: { headers: { Authorization: auth } } });
      const { data, error } = await user.auth.getUser();
      if (error || !data.user) return reply({ error: 'Sign in again' }, 401);
      const body = await request.text();
      if (body.length > 1000) return reply({ error: 'Request too large' }, 413);
      tripId = JSON.parse(body).trip_id;
      if (!tripId || !/^[0-9a-f-]{36}$/i.test(tripId)) return reply({ error: 'Invalid trip' }, 400);
      const { error: access } = await user.rpc('planner_state', { p_trip_id: tripId });
      if (access) return reply({ error: 'Organizer access required; check planner migration is applied' }, 403);
    }
    const db = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    async function runJob() {
      const { data: job, error } = await db.rpc('planner_claim', { p_trip_id: tripId });
      if (error) throw error;
      if (!job) return { status: 'idle' };
      let result = null, failure: string | null = null;
      try { result = await generate(job, Deno.env.get('SERPAPI_API_KEY') ?? '', Deno.env.get('OPEN_METEO_API_KEY')); }
      catch (e) { failure = e instanceof Error ? e.message : 'Planning failed. Request a fresh plan.'; }
      const { data: saved, error: saveError } = await db.rpc('planner_complete', {
        p_trip_id: job.trip_id, p_lease_id: job.lease_id, p_result: result, p_error: failure,
      });
      if (saveError) throw saveError;
      return { status: !saved ? 'changed' : failure ? 'failed' : 'ready' };
    }
    if (scheduled) {
      // Supabase Cron's HTTP form caps the response timeout at five seconds.
      // Register the entire job, including the database claim, before responding.
      EdgeRuntime.waitUntil(runJob().then(result => {
        console.info('Scheduled planner:', result.status);
      }).catch(() => {
        // A claimed job stays leased and can be retried by a later scheduler tick.
        console.error('Scheduled planner failed; check database setup and job state.');
      }));
      return reply({ status: 'accepted' });
    }
    return reply(await runJob());
  } catch {
    // Do not log provider URLs: they include credentials.
    return reply({ error: 'Planner could not run. Check its deployment and retry.' }, 503);
  }
});
