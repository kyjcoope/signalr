final currentEnvironment = Environment.qa2;

enum Environment {
  dev(
    url: 'jci-osp-api-gateway-dev.osp-jci.com',
    signalRUrl: 'jci-osp-api-gateway-dev.osp-jci.com/SignalingHub',
    username: 'UIUser',
    password: 'OSPGateway@123',
  ),
  dev2(
    url: 'jci-osp-api-gateway-dev-2.osp-jci.com',
    signalRUrl: 'jci-osp-api-gateway-dev-2.osp-jci.com/SignalingHub',
    username: 'SANDBOX_ADMIN',
    password: 'Highspan@2026',
  ),
  qa2(
    url: 'jci-osp-api-gateway-dev-2.osp-jci.com',
    signalRUrl: 'jci-osp-api-gateway-qa-2.osp-jci.com/SignalingHub',
    username: 'TESTCITY.JCI.COM',
    password: 'Highspan@2026',
  ),
  qa(
    url: 'jci-osp-api-gateway-qa.osp-jci.com',
    signalRUrl: 'jci-osp-api-gateway-qa.osp-jci.com/SignalingHub',
    username: 'demooperator',
    password: 'Test@12345',
  );

  final String url;
  final String signalRUrl;
  final String username;
  final String password;

  const Environment({
    required this.url,
    required this.signalRUrl,
    required this.username,
    required this.password,
  });
}

String url = currentEnvironment.url;
String signalRUrl = currentEnvironment.signalRUrl;
String username = currentEnvironment.username;
String password = currentEnvironment.password;
