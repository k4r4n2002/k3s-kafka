'use strict';
/**
 * auth-service — JWT Token Validation & User Identity
 * Validates tokens, provides user identity info.
 * Terminal service — no outbound calls.
 */
const express = require('express');
const os = require('os');

const app = express();
const PORT = parseInt(process.env.PORT || '3004', 10);
const SERVICE = process.env.SERVICE_NAME || 'auth-service';
const ENV = process.env.ENVIRONMENT || 'local';

const JWT_SECRET = process.env.JWT_SECRET || 'default-dev-secret';
const API_KEY = process.env.API_KEY || 'default-dev-api-key';

// ── JSON logging helper ─────────────────────────────────────────────────────
function log(level, msg, extra = {}) {
    console.log(JSON.stringify({
        ts: new Date().toISOString(), level, service: SERVICE, env: ENV, msg, ...extra,
    }));
}

// ── Dummy user database ─────────────────────────────────────────────────────
const USERS = {
    'user-001': { id: 'user-001', name: 'Alice Manager', role: 'admin', email: 'alice@example.com' },
    'user-002': { id: 'user-002', name: 'Bob Operator', role: 'editor', email: 'bob@example.com' },
    'user-003': { id: 'user-003', name: 'Charlie Viewer', role: 'viewer', email: 'charlie@example.com' },
};

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

// Validate a token (simplified — accepts "Bearer <userId>" format for demo)
app.get('/validate', (req, res) => {
    const authHeader = req.headers.authorization || '';
    const token = authHeader.replace('Bearer ', '').trim();

    if (!token || token === 'none') {
        log('warn', 'Token validation failed — no token provided');
        return res.status(401).json({ valid: false, error: 'No token provided' });
    }

    // For demo: treat the token as a userId lookup
    const user = USERS[token];
    if (!user) {
        log('warn', 'Token validation failed — unknown token', { token });
        return res.status(401).json({ valid: false, error: 'Invalid token' });
    }

    log('info', 'Token validated successfully', { userId: user.id, role: user.role });
    res.json({ valid: true, user, service: SERVICE, hostname: os.hostname() });
});

// List users (admin endpoint for demo)
app.get('/users', (_req, res) => {
    res.json({ service: SERVICE, users: Object.values(USERS) });
});

// API key validation (for service-to-service auth)
app.post('/verify-api-key', (req, res) => {
    const { key } = req.body;
    if (key === API_KEY) {
        log('info', 'API key validated');
        res.json({ valid: true, service: SERVICE });
    } else {
        log('warn', 'API key validation failed');
        res.status(403).json({ valid: false, error: 'Invalid API key' });
    }
});

// ── Start ───────────────────────────────────────────────────────────────────
app.listen(PORT, () => log('info', `${SERVICE} listening`, { port: PORT }));
