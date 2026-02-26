'use strict';
/**
 * content-service — Content / Media Management
 * CRUD for display content.
 * Fires events to analytics-service via Kafka topic: content-events
 * ClusterIP only — not exposed externally.
 */
const express = require('express');
const os = require('os');
const { Kafka, logLevel } = require('kafkajs');

const app = express();
const PORT = parseInt(process.env.PORT || '3002', 10);
const SERVICE = process.env.SERVICE_NAME || 'content-service';
const ENV = process.env.ENVIRONMENT || 'local';

const KAFKA_BROKERS = (process.env.KAFKA_BROKERS || 'kafka:9092').split(',');
const KAFKA_TOPIC = process.env.KAFKA_TOPIC || 'content-events';

// ── JSON logging helper ─────────────────────────────────────────────────────
function log(level, msg, extra = {}) {
    console.log(JSON.stringify({
        ts: new Date().toISOString(), level, service: SERVICE, env: ENV, msg, ...extra,
    }));
}

// ── Kafka Producer Setup ────────────────────────────────────────────────────
const kafka = new Kafka({
    clientId: SERVICE,
    brokers: KAFKA_BROKERS,
    logLevel: logLevel.WARN,
    retry: {
        initialRetryTime: 300,
        retries: 10,
    },
});

const producer = kafka.producer();
let kafkaReady = false;

async function connectKafka() {
    try {
        await producer.connect();
        kafkaReady = true;
        log('info', 'Kafka producer connected', { brokers: KAFKA_BROKERS, topic: KAFKA_TOPIC });
    } catch (err) {
        log('error', 'Kafka producer connection failed — will retry', { error: err.message });
        // Retry after 5 seconds — service still starts so health checks pass
        setTimeout(connectKafka, 5000);
    }
}

// Publish an analytics event to Kafka (fire-and-forget, non-blocking)
async function trackEvent(action, itemId, extra = {}) {
    if (!kafkaReady) {
        log('warn', 'Kafka not ready — dropping analytics event', { action, itemId });
        return;
    }
    const event = {
        source: SERVICE,
        action,
        itemId: itemId || null,
        ts: new Date().toISOString(),
        env: ENV,
        hostname: os.hostname(),
        ...extra,
    };
    try {
        await producer.send({
            topic: KAFKA_TOPIC,
            messages: [
                {
                    key: itemId || action,
                    value: JSON.stringify(event),
                    headers: { source: SERVICE, env: ENV },
                },
            ],
        });
        log('info', 'Analytics event published to Kafka', { topic: KAFKA_TOPIC, action, itemId });
    } catch (err) {
        log('error', 'Failed to publish event to Kafka', { error: err.message, action, itemId });
    }
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

// ── Routes ──────────────────────────────────────────────────────────────────
app.get('/', (_req, res) => {
    res.json({
        message: `Hello from ${SERVICE}!`,
        env: ENV,
        hostname: os.hostname(),
        kafka: { ready: kafkaReady, brokers: KAFKA_BROKERS, topic: KAFKA_TOPIC },
    });
});

app.get('/health', (_req, res) => {
    // Health check passes even if Kafka is temporarily unavailable
    // Kafka reconnects in the background; the service itself is healthy
    res.json({ status: 'ok', service: SERVICE, env: ENV, kafka: kafkaReady ? 'connected' : 'reconnecting' });
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
    trackEvent('create', item.id, { title, type });
    log('info', 'Content item created', { itemId: item.id });
    res.status(201).json({ service: SERVICE, item });
});

app.delete('/items/:id', (req, res) => {
    const idx = contentItems.findIndex(i => i.id === req.params.id);
    if (idx === -1) return res.status(404).json({ error: 'Not found' });
    const [item] = contentItems.splice(idx, 1);
    trackEvent('delete', item.id);
    log('info', 'Content item deleted', { itemId: item.id });
    res.json({ service: SERVICE, deleted: item });
});

// ── Graceful shutdown ────────────────────────────────────────────────────────
async function shutdown() {
    log('info', 'Shutting down — disconnecting Kafka producer');
    try { await producer.disconnect(); } catch (_) { }
    process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// ── Start ───────────────────────────────────────────────────────────────────
connectKafka().then(() => {
    app.listen(PORT, () => log('info', `${SERVICE} listening`, { port: PORT }));
});