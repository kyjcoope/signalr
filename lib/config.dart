/// Application environment configuration.
enum Environment {
  dev(
    url: 'jci-osp-api-gateway-dev.nonprod.highspansecurity.com',
    username: 'SANDBOX_ADMIN',
    password: 'Highspan@2026',
  ),
  qa(
    url: 'jci-osp-api-gateway-qa.nonprod.highspansecurity.com',
    username: 'TESTPILOT.JCI.COM',
    password: 'Highspan@2026',
  );

  final String url;
  final String username;
  final String password;

  const Environment({
    required this.url,
    required this.username,
    required this.password,
  });
}

/// Current active environment.
const currentEnvironment = Environment.qa;

/// Convenience accessors for current environment values.
String get url => currentEnvironment.url;
String get username => currentEnvironment.username;
String get password => currentEnvironment.password;
