/// Build-time config, supplied with `--dart-define-from-file=env.json`.
/// Only public values belong here (Supabase URL + publishable (anon) key).
class Env {
  static const mapboxToken = String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  static bool get isConfigured =>
      supabaseUrl.startsWith('https://') &&
      !supabaseUrl.contains('YOUR-PROJECT') &&
      supabaseKey.isNotEmpty &&
      !supabaseKey.startsWith('YOUR-');
}
