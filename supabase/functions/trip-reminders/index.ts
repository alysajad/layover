import { createClient } from 'npm:@supabase/supabase-js@2';

function base64url(value: Uint8Array): string {
  return btoa(String.fromCharCode(...value)).replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

async function googleToken(account: { client_email: string; private_key: string }): Promise<string> {
  const encoder = new TextEncoder();
  const now = Math.floor(Date.now() / 1000);
  const header = base64url(encoder.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const claims = base64url(encoder.encode(JSON.stringify({
    iss: account.client_email, scope: 'https://www.googleapis.com/auth/firebase.messaging',
    aud: 'https://oauth2.googleapis.com/token', iat: now, exp: now + 3600,
  })));
  const pem = account.private_key.replace(/-----[^-]+-----|\s/g, '');
  const key = await crypto.subtle.importKey('pkcs8', Uint8Array.from(atob(pem), c => c.charCodeAt(0)),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const assertion = `${header}.${claims}.${base64url(new Uint8Array(await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, encoder.encode(`${header}.${claims}`))))}`;
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }),
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error('FCM authentication failed');
  return (await response.json()).access_token;
}

Deno.serve(async request => {
  const secret = Deno.env.get('REMINDER_SECRET');
  if (!secret || request.headers.get('x-reminder-secret') !== secret) return new Response('Unauthorized', { status: 401 });
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  try {
    const { error: queueError } = await db.rpc('enqueue_trip_reminders');
    if (queueError) throw queueError;
    const firebase = Deno.env.get('FIREBASE_SERVICE_ACCOUNT');
    if (!firebase) return Response.json({ queued: true, push: 'not_configured' });
    const account = JSON.parse(firebase);
    const accessToken = await googleToken(account);
    const { data: notifications, error } = await db.rpc('claim_trip_notifications');
    if (error) throw error;
    let sent = 0;
    for (const notification of notifications ?? []) {
      const { data: member, error: memberError } = await db.from('trip_members').select('user_id')
        .eq('trip_id', notification.trip_id).eq('user_id', notification.user_id).eq('membership_status', 'joined').maybeSingle();
      const { data: profile, error: profileError } = await db.from('profiles').select('reminders_enabled').eq('id', notification.user_id).single();
      if (memberError || profileError) throw new Error('Could not verify notification recipient');
      if (!member || !profile?.reminders_enabled) {
        const { error } = await db.from('trip_notifications').update({ pushed_at: new Date().toISOString() }).eq('id', notification.id);
        if (error) throw error;
        continue;
      }
      const { data: devices, error: tokenError } = await db.from('device_tokens').select('token').eq('user_id', notification.user_id);
      if (tokenError) throw tokenError;
      let delivered = true;
      for (const device of devices ?? []) {
        const response = await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
          method: 'POST', headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: { token: device.token,
            notification: { title: 'Layover', body: 'Your trip has an update.' },
            data: { trip_id: notification.trip_id, notification_id: notification.id },
            android: { notification: { tag: notification.id } },
          } }), signal: AbortSignal.timeout(15000),
        });
        if (!response.ok) {
          const body = await response.json();
          if (body.error?.details?.some((detail: { errorCode?: string }) => detail.errorCode === 'UNREGISTERED')) {
            const { error } = await db.from('device_tokens').delete().eq('token', device.token);
            if (error) throw error;
          } else delivered = false;
        }
      }
      if (delivered) {
        const { error } = await db.from('trip_notifications').update({ pushed_at: new Date().toISOString() }).eq('id', notification.id);
        if (error) throw error;
        sent++;
      }
    }
    return Response.json({ queued: true, sent });
  } catch (error) {
    // Never log device tokens, request headers, service-account data, or full payloads.
    console.error('Trip reminder delivery failed', error instanceof Error ? error.name : 'DatabaseError');
    return Response.json({ error: 'Reminder worker failed; inspect delivery status and retry.' }, { status: 500 });
  }
});
