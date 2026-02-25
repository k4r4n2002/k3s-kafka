'use strict';
/**
 * content-service — Content / Media Management
 * CRUD for display content. Fires events to analytics-service.
 * ClusterIP only — not exposed externally.
 */
const express = require('express');
const os = require('os');

const app = express();
const PORT = parseInt(process.env.PORT || '3002', 10);
const SERVICE = process.env.SERVICE_NAME || 'content-service';
const ENV = process.env.ENVIRONMENT || 'local';

const ANALYTICS_URL = process.env.ANALYTICS_SERVICE_URL || 'http://analytics-service:3003';

// ── JSON logging helper ─────────────────────────────────────────────────────
function log(level, msg, extra = {}) {
    console.log(JSON.stringify({
        ts: new Date().toISOString(), level, service: SERVICE, env: ENV, msg, ...extra,
    }));
}

// ── In-memory content store ─────────────────────────────────────────────────
let contentItems = [
    { id: 'C001', title: 'Welcome Banner', type: 'image', status: 'active', createdAt: '2025-01-15' },
    { id: 'C002', title: 'Product Showcase', type: 'video', status: 'active', createdAt: '2025-02-01' },
    { id: 'C003', title: 'Holiday Promo', type: 'html', status: 'draft', createdAt: '2025-03-10' },
    { id: 'C004', title: 'Digital Menu Board', type: 'image', status: 'archived', createdAt: '2024-11-20' },
];

// ── Middleware ───────────────────────────────────────────────────────────────
app.use(express.json());
app.use((req, _res, next) => {
    log('info', `${req.method} ${req.path}`);
    next();
});

// Fire-and-forget analytics event
async function trackEvent(action, itemId) {
    try {
        await fetch(`${ANALYTICS_URL}/events`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ source: SERVICE, action, itemId, ts: new Date().toISOString() }),
        });
    } catch (err) {
        log('warn', 'Analytics event failed (non-blocking)', { error: err.message });
    }
}

// ── Routes ──────────────────────────────────────────────────────────────────
app.get('/', (_req, res) => {
    res.json({ message: `Hello from ${SERVICE}!`, env: ENV, hostname: os.hostname() });
});

app.get('/health', (_req, res) => {
    res.json({ status: 'ok', service: SERVICE, env: ENV });
});

app.get('/items', (_req, res) => {
    res.json({ service: SERVICE, hostname: os.hostname(), items: contentItems });
});

app.get('/items/:id', (req, res) => {
    const item = contentItems.find(i => i.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Not found' });
    trackEvent('view', item.id);
    res.json({ service: SERVICE, item });
});

app.post('/items', (req, res) => {
    const { title, type } = req.body;
    if (!title || !type) return res.status(400).json({ error: 'title and type required' });
    const item = {
        id: `C${String(contentItems.length + 1).padStart(3, '0')}`,
        title, type, status: 'draft', createdAt: new Date().toISOString().split('T')[0],
    };
    contentItems.push(item);
    trackEvent('create', item.id);
    log('info', 'Content item created', { itemId: item.id });
    res.status(201).json({ service: SERVICE, item });
});

// ── Start ───────────────────────────────────────────────────────────────────
app.listen(PORT, () => log('info', `${SERVICE} listening`, { port: PORT }));
