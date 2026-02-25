'use strict';
/**
 * analytics-service — Analytics Ingestion & Retrieval
 * Receives events from other services, stores in-memory, exposes query API.
 * Terminal service — no outbound calls.
 */
const express = require('express');
const os = require('os');

const app = express();
const PORT = parseInt(process.env.PORT || '3003', 10);
const SERVICE = process.env.SERVICE_NAME || 'analytics-service';
const ENV = process.env.ENVIRONMENT || 'local';

// ── JSON logging helper ─────────────────────────────────────────────────────
function log(level, msg, extra = {}) {
    console.log(JSON.stringify({
        ts: new Date().toISOString(), level, service: SERVICE, env: ENV, msg, ...extra,
    }));
}

// ── In-memory event store ───────────────────────────────────────────────────
const events = [];

// ── Middleware ───────────────────────────────────────────────────────────────
app.use(express.json());
app.use((req, _res, next) => {
    log('info', `${req.method} ${req.path}`);
    next();
});

// ── Routes ──────────────────────────────────────────────────────────────────
app.get('/', (_req, res) => {
    res.json({ message: `Hello from ${SERVICE}!`, env: ENV, hostname: os.hostname() });
});

app.get('/health', (_req, res) => {
    res.json({ status: 'ok', service: SERVICE, env: ENV });
});

// Ingest an event (called by content-service, api-gateway, etc.)
app.post('/events', (req, res) => {
    const { source, action, itemId, ts } = req.body;
    if (!source || !action) return res.status(400).json({ error: 'source and action required' });
    const event = {
        id: `E${String(events.length + 1).padStart(5, '0')}`,
        source, action, itemId: itemId || null,
        ts: ts || new Date().toISOString(),
        receivedAt: new Date().toISOString(),
    };
    events.push(event);
    log('info', 'Event ingested', { eventId: event.id, source, action });
    res.status(201).json({ service: SERVICE, event });
});

// Query events
app.get('/events', (req, res) => {
    const { source, action, limit } = req.query;
    let result = [...events];
    if (source) result = result.filter(e => e.source === source);
    if (action) result = result.filter(e => e.action === action);
    const max = parseInt(limit || '50', 10);
    result = result.slice(-max);
    res.json({ service: SERVICE, hostname: os.hostname(), total: events.length, returned: result.length, events: result });
});

// Summary / stats
app.get('/stats', (_req, res) => {
    const bySource = {};
    const byAction = {};
    events.forEach(e => {
        bySource[e.source] = (bySource[e.source] || 0) + 1;
        byAction[e.action] = (byAction[e.action] || 0) + 1;
    });
    res.json({ service: SERVICE, totalEvents: events.length, bySource, byAction });
});

// ── Start ───────────────────────────────────────────────────────────────────
app.listen(PORT, () => log('info', `${SERVICE} listening`, { port: PORT }));
