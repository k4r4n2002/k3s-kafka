'use strict';
/**
 * analytics-service — Analytics Ingestion & Retrieval
 * Consumes events from Kafka topic: content-events
 * Also exposes a query API for reading stored events.
 * Terminal service — no outbound calls.
 */
const express = require('express');
const os = require('os');
const { Kafka, logLevel } = require('kafkajs');

const app = express();
const PORT = parseInt(process.env.PORT || '3003', 10);
const SERVICE = process.env.SERVICE_NAME || 'analytics-service';
const ENV = process.env.ENVIRONMENT || 'local';

const KAFKA_BROKERS = (process.env.KAFKA_BROKERS || 'kafka:9092').split(',');
const KAFKA_TOPIC = process.env.KAFKA_TOPIC || 'content-events';
const KAFKA_GROUP_ID = process.env.KAFKA_GROUP_ID || 'analytics-consumers';

// ── JSON logging helper ─────────────────────────────────────────────────────
function log(level, msg, extra = {}) {
    console.log(JSON.stringify({
        ts: new Date().toISOString(), level, service: SERVICE, env: ENV, msg, ...extra,
    }));
}

// ── In-memory event store ───────────────────────────────────────────────────
const events = [];
let consumerConnected = false;
let messagesConsumed = 0;

// ── Kafka Consumer Setup ────────────────────────────────────────────────────
const kafka = new Kafka({
    clientId: SERVICE,
    brokers: KAFKA_BROKERS,
    logLevel: logLevel.WARN,
    retry: {
        initialRetryTime: 300,
        retries: 10,
    },
});

const consumer = kafka.consumer({ groupId: KAFKA_GROUP_ID });

async function startConsumer() {
    try {
        await consumer.connect();
        await consumer.subscribe({ topic: KAFKA_TOPIC, fromBeginning: true });

        consumerConnected = true;
        log('info', 'Kafka consumer connected and subscribed', {
            brokers: KAFKA_BROKERS,
            topic: KAFKA_TOPIC,
            groupId: KAFKA_GROUP_ID,
        });

        await consumer.run({
            eachMessage: async ({ topic, partition, message }) => {
                try {
                    const raw = message.value.toString();
                    const payload = JSON.parse(raw);

                    const event = {
                        id: `E${String(events.length + 1).padStart(5, '0')}`,
                        source: payload.source || 'unknown',
                        action: payload.action || 'unknown',
                        itemId: payload.itemId || null,
                        ts: payload.ts || new Date().toISOString(),
                        receivedAt: new Date().toISOString(),
                        // Kafka metadata
                        kafka: {
                            topic,
                            partition,
                            offset: message.offset,
                            key: message.key ? message.key.toString() : null,
                        },
                    };

                    events.push(event);
                    messagesConsumed++;

                    log('info', 'Event consumed from Kafka', {
                        eventId: event.id,
                        source: event.source,
                        action: event.action,
                        offset: message.offset,
                        partition,
                    });
                } catch (err) {
                    log('error', 'Failed to process Kafka message', { error: err.message });
                }
            },
        });
    } catch (err) {
        consumerConnected = false;
        log('error', 'Kafka consumer failed — will retry in 5s', { error: err.message });
        setTimeout(startConsumer, 5000);
    }
}

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
        kafka: {
            connected: consumerConnected,
            brokers: KAFKA_BROKERS,
            topic: KAFKA_TOPIC,
            groupId: KAFKA_GROUP_ID,
            messagesConsumed,
        },
    });
});

app.get('/health', (_req, res) => {
    res.json({
        status: 'ok',
        service: SERVICE,
        env: ENV,
        kafka: consumerConnected ? 'connected' : 'reconnecting',
    });
});

// Query events (consumed from Kafka)
app.get('/events', (req, res) => {
    const { source, action, limit } = req.query;
    let result = [...events];
    if (source) result = result.filter(e => e.source === source);
    if (action) result = result.filter(e => e.action === action);
    const max = parseInt(limit || '50', 10);
    result = result.slice(-max);
    res.json({
        service: SERVICE,
        hostname: os.hostname(),
        total: events.length,
        returned: result.length,
        events: result,
    });
});

// Summary / stats
app.get('/stats', (_req, res) => {
    const bySource = {};
    const byAction = {};
    events.forEach(e => {
        bySource[e.source] = (bySource[e.source] || 0) + 1;
        byAction[e.action] = (byAction[e.action] || 0) + 1;
    });
    res.json({
        service: SERVICE,
        totalEvents: events.length,
        messagesConsumed,
        kafka: {
            connected: consumerConnected,
            topic: KAFKA_TOPIC,
            groupId: KAFKA_GROUP_ID,
        },
        bySource,
        byAction,
    });
});

// Kafka consumer health/lag info
app.get('/kafka-status', (_req, res) => {
    res.json({
        service: SERVICE,
        kafka: {
            connected: consumerConnected,
            brokers: KAFKA_BROKERS,
            topic: KAFKA_TOPIC,
            groupId: KAFKA_GROUP_ID,
            messagesConsumed,
            eventsStored: events.length,
        },
    });
});

// ── Graceful shutdown ────────────────────────────────────────────────────────
async function shutdown() {
    log('info', 'Shutting down — disconnecting Kafka consumer');
    try { await consumer.disconnect(); } catch (_) { }
    process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// ── Start ───────────────────────────────────────────────────────────────────
// HTTP server starts immediately so liveness/readiness probes pass from the start.
// Kafka consumer connects in the background and retries automatically on failure.
app.listen(PORT, () => log('info', `${SERVICE} listening`, { port: PORT }));
startConsumer();