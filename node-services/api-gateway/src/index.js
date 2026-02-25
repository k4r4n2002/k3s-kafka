'use strict';
/**
 * api-gateway — Public HTTP Gateway
 * Routes requests to internal services (content-service, auth-service).
 * Exposed externally via NodePort/Ingress.
 */
const express = require('express');
const os = require('os');

const app = express();
const PORT = parseInt(process.env.PORT || '3001', 10);
const SERVICE = process.env.SERVICE_NAME || 'api-gateway';
const ENV = process.env.ENVIRONMENT || 'local';

const CONTENT_URL = process.env.CONTENT_SERVICE_URL || 'http://content-service:3002';
const AUTH_URL = process.env.AUTH_SERVICE_URL || 'http://auth-service:3004';

// ── JSON logging helper ─────────────────────────────────────────────────────
function log(level, msg, extra = {}) {
    console.log(JSON.stringify({
        ts: new Date().toISOString(), level, service: SERVICE, env: ENV, msg, ...extra,
    }));
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
        time: new Date().toISOString(),
    });
});

app.get('/health', (_req, res) => {
    res.json({ status: 'ok', service: SERVICE, env: ENV });
});

app.get('/info', (_req, res) => {
    res.json({
        service: SERVICE,
        env: ENV,
        hostname: os.hostname(),
        pid: process.pid,
        uptime: process.uptime(),
        node: process.version,
    });
});

// Proxy to content-service
app.get('/content', async (_req, res) => {
    try {
        const response = await fetch(`${CONTENT_URL}/items`);
        if (!response.ok) throw new Error(`content-service returned ${response.status}`);
        const data = await response.json();
        log('info', 'Upstream call to content-service succeeded');
        res.json({ from: SERVICE, contentResponse: data });
    } catch (err) {
        log('error', 'Upstream call to content-service failed', { error: err.message });
        res.status(502).json({ error: err.message, from: SERVICE });
    }
});

// Proxy to auth-service
app.get('/verify-token', async (req, res) => {
    try {
        const token = req.headers.authorization || 'none';
        const response = await fetch(`${AUTH_URL}/validate`, {
            headers: { authorization: token },
        });
        if (!response.ok) throw new Error(`auth-service returned ${response.status}`);
        const data = await response.json();
        log('info', 'Token validation via auth-service succeeded');
        res.json({ from: SERVICE, authResponse: data });
    } catch (err) {
        log('error', 'Token validation failed', { error: err.message });
        res.status(502).json({ error: err.message, from: SERVICE });
    }
});

// ── Start ───────────────────────────────────────────────────────────────────
app.listen(PORT, () => log('info', `${SERVICE} listening`, { port: PORT }));
