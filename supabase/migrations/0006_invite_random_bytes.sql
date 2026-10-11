-- Supabase installs pgcrypto in extensions; local databases may use public.
-- Migration 0005 renamed the invite implementation to companion_command_base.
alter function public.companion_command_base(text,jsonb,uuid)
  set search_path = public, extensions;
