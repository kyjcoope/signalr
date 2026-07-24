// Firebase Cloud Messaging service worker for the CSP-safe/raw-push path.
//
// Deployment requirements that code cannot enforce:
// - Serve this exact file from /firebase-messaging-sw.js over trusted HTTPS.
// - Return JavaScript (not the Flutter index.html SPA fallback) with no redirect.
// - Prefer Cache-Control: no-cache so worker updates are discovered promptly.
// - Do not add Firebase CDN importScripts() calls to this worker.

const WORKER_VERSION = '2026-07-24.1';
const ACTIVE_LEASE_TTL_MS = 15000;
const PUSH_DEDUP_TTL_MS = 8000;
const CLIENT_READY_TIMEOUT_MS = 10000;

const activeTabLeases = new Map();
const recentPushFingerprints = new Map();
const readyClientIds = new Set();
const clientReadyWaiters = new Map();

function toObject(value) {
  if (!value) return null;
  if (typeof value === 'object') return value;
  if (typeof value === 'string') {
    try {
      const parsed = JSON.parse(value);
      return typeof parsed === 'object' && parsed ? parsed : null;
    } catch (_) {
      return null;
    }
  }
  return null;
}

function normalizeNotificationData(input) {
  const base = toObject(input) || {};
  const normalized = Object.assign({}, base);
  const fcm = toObject(base.FCM_MSG);
  const nestedData = toObject(fcm && fcm.data);

  if (nestedData) {
    for (const [key, value] of Object.entries(nestedData)) {
      if (normalized[key] === undefined) {
        normalized[key] = value;
      }
    }
  }

  const notification = toObject(fcm && fcm.notification);
  if (
    !normalized.title &&
    notification &&
    typeof notification.title === 'string'
  ) {
    normalized.title = notification.title;
  }
  if (
    !normalized.body &&
    notification &&
    typeof notification.body === 'string'
  ) {
    normalized.body = notification.body;
  }

  return normalized;
}

function cleanupExpiredLeases(nowMs = Date.now()) {
  for (const [tabId, lease] of activeTabLeases.entries()) {
    if (!lease || lease.expiresAt <= nowMs) {
      activeTabLeases.delete(tabId);
    }
  }
}

function cleanupExpiredPushFingerprints(nowMs = Date.now()) {
  for (const [fingerprint, expiresAt] of recentPushFingerprints.entries()) {
    if (expiresAt <= nowMs) {
      recentPushFingerprints.delete(fingerprint);
    }
  }
}

function pushFingerprint(payload) {
  const notification = (payload && payload.notification) || {};
  const data = (payload && payload.data) || {};
  const messageId =
    (payload && (payload.fcmMessageId || payload.messageId)) ||
    data['google.message_id'] ||
    data['gcm.message_id'] ||
    '';

  if (messageId) {
    return `messageId:${messageId}`;
  }

  const title = notification.title || '';
  const body = notification.body || '';
  const sortedKeys = Object.keys(data).sort();
  const dataSignature = sortedKeys
    .map((key) => `${key}=${String(data[key])}`)
    .join('&');
  return `${title}|${body}|${dataSignature}`;
}

function isDuplicatePush(payload, nowMs = Date.now()) {
  cleanupExpiredPushFingerprints(nowMs);
  const fingerprint = pushFingerprint(payload);
  if (recentPushFingerprints.has(fingerprint)) {
    return true;
  }

  recentPushFingerprints.set(fingerprint, nowMs + PUSH_DEDUP_TTL_MS);
  return false;
}

function sourceClientId(event) {
  const source = event && event.source;
  return source && typeof source.id === 'string' ? source.id : null;
}

function resolveClientReadyWaiters(clientId) {
  const waiters = clientReadyWaiters.get(clientId);
  if (!waiters) return;

  clientReadyWaiters.delete(clientId);
  for (const resolve of waiters) {
    resolve(true);
  }
}

function markClientReady(clientId) {
  if (!clientId) return;
  readyClientIds.add(clientId);
  resolveClientReadyWaiters(clientId);
}

function waitForClientReady(clientId, timeoutMs = CLIENT_READY_TIMEOUT_MS) {
  if (!clientId || readyClientIds.has(clientId)) {
    return Promise.resolve(true);
  }

  return new Promise((resolve) => {
    const waiters = clientReadyWaiters.get(clientId) || new Set();
    clientReadyWaiters.set(clientId, waiters);

    let completed = false;
    const complete = (ready) => {
      if (completed) return;
      completed = true;
      clearTimeout(timeout);
      waiters.delete(waiter);
      if (waiters.size === 0) {
        clientReadyWaiters.delete(clientId);
      }
      resolve(ready);
    };
    const waiter = () => complete(true);
    const timeout = setTimeout(() => complete(false), timeoutMs);
    waiters.add(waiter);
  });
}

function postJson(client, value) {
  if (!client) return false;
  try {
    client.postMessage(JSON.stringify(value));
    return true;
  } catch (_) {
    return false;
  }
}

async function matchingWindowClients() {
  return self.clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
  });
}

async function postPushToActiveClient(payload) {
  const nowMs = Date.now();
  cleanupExpiredLeases(nowMs);
  if (activeTabLeases.size === 0) return false;

  const clients = await matchingWindowClients();
  const clientsById = new Map(clients.map((client) => [client.id, client]));
  const leases = Array.from(activeTabLeases.values()).sort(
    (a, b) => b.lastSeenAt - a.lastSeenAt,
  );

  for (const lease of leases) {
    const client = clientsById.get(lease.clientId);
    if (!client) continue;

    return postJson(client, {
      type: 'FCM_PUSH',
      workerVersion: WORKER_VERSION,
      payload,
    });
  }

  return false;
}

function bestClientForClick(clientList) {
  cleanupExpiredLeases();
  const clientsById = new Map(clientList.map((client) => [client.id, client]));
  const leases = Array.from(activeTabLeases.values()).sort(
    (a, b) => b.lastSeenAt - a.lastSeenAt,
  );

  for (const lease of leases) {
    const leasedClient = clientsById.get(lease.clientId);
    if (leasedClient) return leasedClient;
  }

  return (
    clientList.find((client) => client.focused) ||
    clientList.find((client) => client.visibilityState === 'visible') ||
    clientList[0] ||
    null
  );
}

async function postClickWhenClientReady(client, clickMessage, waitForReady) {
  if (!client) return false;

  if (waitForReady || !readyClientIds.has(client.id)) {
    postJson(client, {
      type: 'SW_READY_PROBE',
      workerVersion: WORKER_VERSION,
    });
    await waitForClientReady(
      client.id,
      waitForReady ? CLIENT_READY_TIMEOUT_MS : 1500,
    );
  }

  return postJson(client, clickMessage);
}

self.addEventListener('message', (event) => {
  try {
    const raw = event.data;
    let message = raw;

    if (typeof raw === 'string') {
      try {
        message = JSON.parse(raw);
      } catch (_) {
        return;
      }
    }

    if (!message || typeof message !== 'object') return;

    const clientId = sourceClientId(event);
    if (message.type === 'APP_CLIENT_READY') {
      markClientReady(clientId);
      return;
    }

    if (message.type !== 'APP_ACTIVE_STATE') return;

    const tabId = typeof message.tabId === 'string' ? message.tabId : '';
    if (!tabId || !clientId) return;

    if (message.active === true) {
      const nowMs = Date.now();
      activeTabLeases.set(tabId, {
        clientId,
        expiresAt: nowMs + ACTIVE_LEASE_TTL_MS,
        lastSeenAt: nowMs,
        url: typeof message.url === 'string' ? message.url : '',
      });
    } else {
      activeTabLeases.delete(tabId);
    }
  } catch (_) {
    // Ignore malformed app activity messages.
  }
});

// Register click handling before push handling so there is only one click path.
self.addEventListener('notificationclick', (event) => {
  event.notification.close();

  const normalizedPayload = normalizeNotificationData(event.notification.data);
  const route = normalizedPayload.route || '/';
  const deepLink = normalizedPayload.deepLink;
  const clickMessage = {
    type: 'NOTIFICATION_CLICK',
    clickId: `${Date.now()}-${Math.random().toString(36).slice(2)}`,
    workerVersion: WORKER_VERSION,
    route,
    deepLink,
    payload: normalizedPayload,
  };

  event.waitUntil(
    matchingWindowClients().then(async (clientList) => {
      if (clientList.length > 0) {
        const client = bestClientForClick(clientList);
        await postClickWhenClientReady(client, clickMessage, false);
        if (client && client.focus) {
          await client.focus();
        }
        return;
      }

      if (!self.clients.openWindow) return;

      const openedClient = await self.clients.openWindow(route || '/');
      if (!openedClient) return;

      await postClickWhenClientReady(openedClient, clickMessage, true);
      if (openedClient.focus) {
        await openedClient.focus();
      }
    }),
  );
});

// Activate updated code immediately. Server/proxy cache headers must still
// allow the browser to retrieve this file.
self.addEventListener('install', (event) => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

// This worker intentionally handles the decrypted Web Push payload directly.
// It does not depend on Firebase compat CDN scripts, so restrictive CSP or
// enterprise blocking of gstatic.com cannot make worker evaluation fail.
self.addEventListener('push', (event) => {
  let payload;
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    return;
  }

  if (isDuplicatePush(payload)) return;

  const data = toObject(payload.data) || {};
  const notification = toObject(payload.notification) || {};
  const normalizedData = normalizeNotificationData(
    Object.assign({}, data, {
      FCM_MSG: payload,
      route: data.route || '/',
      deepLink: data.deepLink,
    }),
  );

  const title = notification.title || data.title || 'exacqVision';
  const body = notification.body || data.body || '';
  const options = {
    body,
    icon: '/icons/android-chrome-192x192.png',
    badge: '/icons/android-chrome-192x192.png',
    data: normalizedData,
  };

  event.waitUntil(
    postPushToActiveClient(payload).then((delivered) => {
      if (delivered) return undefined;
      return self.registration.showNotification(title, options);
    }),
  );
});
