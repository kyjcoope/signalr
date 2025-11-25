final currentEnvironment = Environment.qa;

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

String url = currentEnvironment.url;
String username = currentEnvironment.username;
String password = currentEnvironment.password;
