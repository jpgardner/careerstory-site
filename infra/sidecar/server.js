// CareerStory edge sidecar.
// Listens on 127.0.0.1:9000. Three responsibilities:
//   GET  /check?domain=foo.com   ->  Caddy on-demand TLS gate.
//   POST /api/stripe-webhook     ->  flips clients.json on payment events.
//   GET  /healthz                ->  uptime probe.
//
// Reads and writes /etc/careerstory/clients.json (path overridable
// via CLIENTS_JSON). Stripe signing secret comes from STRIPE_WEBHOOK_SECRET.
//
// Run as a systemd service. See infra/bin/provision-vps.sh for the unit.

const http = require('http');
const fs = require('fs');
const Stripe = require('stripe');

const PORT = parseInt(process.env.PORT || '9000', 10);
const CLIENTS_JSON = process.env.CLIENTS_JSON || '/etc/careerstory/clients.json';
const STRIPE_KEY = process.env.STRIPE_SECRET_KEY || '';
const STRIPE_WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || '';
const GRACE_DAYS = parseInt(process.env.GRACE_DAYS || '14', 10);

const stripe = STRIPE_KEY ? Stripe(STRIPE_KEY) : null;

function loadClients() {
  try {
    return JSON.parse(fs.readFileSync(CLIENTS_JSON, 'utf8'));
  } catch (err) {
    if (err.code === 'ENOENT') return { clients: [] };
    throw err;
  }
}

function saveClients(data) {
  const tmp = CLIENTS_JSON + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2));
  fs.renameSync(tmp, CLIENTS_JSON);
}

function findByDomain(data, domain) {
  return data.clients.find(c => c.domain.toLowerCase() === domain.toLowerCase());
}

function findByCustomer(data, customerId) {
  return data.clients.find(c => c.stripe_customer_id === customerId);
}

function isLiveStatus(status) {
  return status === 'active' || status === 'grace';
}

function readBody(req, limit = 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on('data', chunk => {
      total += chunk.length;
      if (total > limit) {
        reject(new Error('payload too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function handleCheck(req, res, url) {
  const domain = (url.searchParams.get('domain') || '').trim();
  if (!domain) {
    res.writeHead(400).end('missing domain');
    return;
  }
  const data = loadClients();
  const entry = findByDomain(data, domain);
  if (entry && isLiveStatus(entry.status)) {
    res.writeHead(200).end('ok');
    return;
  }
  res.writeHead(403).end('not allowed');
}

async function handleStripeWebhook(req, res) {
  if (!stripe || !STRIPE_WEBHOOK_SECRET) {
    res.writeHead(503).end('stripe not configured');
    return;
  }
  const sig = req.headers['stripe-signature'];
  if (!sig) {
    res.writeHead(400).end('missing signature');
    return;
  }
  let raw;
  try {
    raw = await readBody(req, 256 * 1024);
  } catch (err) {
    res.writeHead(413).end('payload too large');
    return;
  }
  let event;
  try {
    event = stripe.webhooks.constructEvent(raw, sig, STRIPE_WEBHOOK_SECRET);
  } catch (err) {
    console.error('stripe signature verification failed:', err.message);
    res.writeHead(400).end('bad signature');
    return;
  }

  const data = loadClients();
  const now = new Date().toISOString();

  switch (event.type) {
    case 'invoice.payment_failed': {
      const customerId = event.data.object.customer;
      const entry = findByCustomer(data, customerId);
      if (entry && entry.status === 'active') {
        entry.status = 'grace';
        entry.grace_started_at = now;
        entry.grace_ends_at = new Date(Date.now() + GRACE_DAYS * 86400000).toISOString();
        saveClients(data);
        console.log(`payment_failed: ${entry.domain} -> grace`);
      }
      break;
    }
    case 'invoice.payment_succeeded': {
      const customerId = event.data.object.customer;
      const entry = findByCustomer(data, customerId);
      if (entry && entry.status === 'grace') {
        entry.status = 'active';
        delete entry.grace_started_at;
        delete entry.grace_ends_at;
        saveClients(data);
        console.log(`payment_succeeded: ${entry.domain} -> active`);
      }
      break;
    }
    case 'customer.subscription.deleted': {
      const customerId = event.data.object.customer;
      const entry = findByCustomer(data, customerId);
      if (entry) {
        entry.status = 'suspended';
        entry.suspended_at = now;
        saveClients(data);
        console.log(`subscription.deleted: ${entry.domain} -> suspended`);
      }
      break;
    }
    default:
      // ignore everything else
      break;
  }

  res.writeHead(200).end('ok');
}

function handleHealthz(req, res) {
  let registry = 'unknown';
  try {
    const data = loadClients();
    registry = `${data.clients.length} clients`;
  } catch (err) {
    registry = 'unreadable';
  }
  res.writeHead(200, { 'content-type': 'application/json' }).end(
    JSON.stringify({ ok: true, registry, ts: new Date().toISOString() })
  );
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  try {
    if (req.method === 'GET' && url.pathname === '/check') return handleCheck(req, res, url);
    if (req.method === 'POST' && url.pathname === '/api/stripe-webhook') return handleStripeWebhook(req, res);
    if (req.method === 'GET' && url.pathname === '/healthz') return handleHealthz(req, res);
    res.writeHead(404).end('not found');
  } catch (err) {
    console.error('handler error:', err);
    if (!res.headersSent) res.writeHead(500).end('error');
  }
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`careerstory-sidecar listening on 127.0.0.1:${PORT}`);
  console.log(`registry: ${CLIENTS_JSON}`);
  console.log(`stripe: ${stripe ? 'configured' : 'not configured'}`);
});
