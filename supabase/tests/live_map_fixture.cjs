// Run with Node and @electric-sql/pglite installed. No hosted database is touched.
const { PGlite } = require('@electric-sql/pglite');
const { pgcrypto } = require('@electric-sql/pglite/contrib/pgcrypto');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');


async function createDatabase() {
  const db = new PGlite({ extensions: { pgcrypto } });
  await db.exec(`
    create role anon; create role authenticated; create role service_role bypassrls;
    create schema auth; create schema storage;
    create table auth.users(id uuid primary key,email text,raw_user_meta_data jsonb default '{}');
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text);
    alter table storage.objects enable row level security;
    create function storage.foldername(text) returns text[] language sql as $$ select string_to_array($1,'/') $$;
    grant usage on schema public,auth,storage to authenticated,anon,service_role;
  `);
  for (const file of ['0001_init.sql','0002_companion.sql','0003_live_map.sql']) {
    try { await db.exec(readFileSync(join(__dirname,'../migrations',file),'utf8')); }
    catch (error) { console.error(`Migration failed: ${file}`, error.message, error.position); throw error; }
  }
  return db;
}
module.exports = {createDatabase};
