/// Build-time config, supplied with `--dart-define-from-file=env.json`.
/// Only public values belong here; Google OAuth secrets stay in Supabase.
class Env {
  static const nativeAuthRedirect = 'com.layover.layover://login-callback/';

  /// Retain invitation links, but never replay a previous OAuth code or error.
  static String authRedirect({Uri? webUri}) {
    if (webUri == null) return nativeAuthRedirect;
    final parameters = {
      for (final key in ['invite', 'live_session'])
        if (webUri.queryParameters.containsKey(key))
          key: webUri.queryParameters[key]!,
    };
    return Uri(
      scheme: webUri.scheme,
      host: webUri.host,
      port: webUri.hasPort ? webUri.port : null,
      path: webUri.path,
      queryParameters: parameters.isEmpty ? null : parameters,
    ).toString();
  }

  static const mapboxToken = String.fromEnvironment('MAPBOX_PUBLIC_TOKEN');
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseKey = String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');

  static bool get isConfigured =>
      supabaseUrl.startsWith('https://') &&
      !supabaseUrl.contains('YOUR-PROJECT') &&
      supabaseKey.isNotEmpty &&
      !supabaseKey.startsWith('YOUR-');
}
