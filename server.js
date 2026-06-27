// Product Insight Analysis System - Node.js Server
// Replaces serve.ps1 for cross-platform deployment
const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const app = express();
const PORT = process.env.PORT || 9876;

app.use(express.json({ limit: '10mb' }));
app.use(express.static(__dirname));

// ===== API Proxy: DeepSeek =====
app.post('/api/proxy', async (req, res) => {
    try {
        const { model, messages, max_tokens, temperature, stream } = req.body;
        const apiKey = req.headers['x-local-api-key'];
        const provider = req.headers['x-api-provider'] || 'deepseek';
        if (!apiKey) return res.status(400).json({ error: 'Missing x-local-api-key header' });

        const apiUrl = provider === 'anthropic'
            ? 'https://api.anthropic.com/v1/messages'
            : 'https://api.deepseek.com/v1/chat/completions';

        const headers = { 'Content-Type': 'application/json' };
        if (provider === 'anthropic') {
            headers['x-api-key'] = apiKey;
            headers['anthropic-version'] = '2023-06-01';
        } else {
            headers['Authorization'] = `Bearer ${apiKey}`;
        }

        const fetchResp = await fetch(apiUrl, {
            method: 'POST', headers,
            body: JSON.stringify(req.body),
        });

        if (!fetchResp.ok) {
            const err = await fetchResp.text();
            return res.status(fetchResp.status).send(err);
        }

        // Stream response back
        res.setHeader('Content-Type', fetchResp.headers.get('content-type') || 'application/json');
        const reader = fetchResp.body.getReader();
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            res.write(Buffer.from(value));
        }
        res.end();
    } catch (e) {
        res.status(502).json({ error: e.message });
    }
});

// ===== Helper: spawn Python script and stream SSE =====
function spawnPython(script, args, res, envVars = {}) {
    res.writeHead(200, {
        'Content-Type': 'text/event-stream; charset=utf-8',
        'Cache-Control': 'no-cache',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no',
    });

    const env = { ...process.env, PYTHONUNBUFFERED: '1', PYTHONIOENCODING: 'utf-8', ...envVars };
    const py = spawn('python3', [script, ...args], { env });

    py.stdout.on('data', (data) => {
        const lines = data.toString().split('\n');
        for (const line of lines) {
            if (line.startsWith('STATUS:')) {
                const json = line.substring(7);
                res.write(`data: {"type":"progress",${json.substring(1)}}\n\n`);
            } else if (line.startsWith('DATA:')) {
                const json = line.substring(5);
                res.write(`data: {"type":"result",${json.substring(1)}}\n\n`);
                res.end();
                py.kill();
                return;
            }
        }
    });

    py.stderr.on('data', (data) => {
        console.error(`[${path.basename(script)}] ${data.toString().trim()}`);
    });

    py.on('close', () => {
        if (!res.writableEnded) res.end();
    });
}

// ===== Fetch JD Reviews =====
app.post('/api/fetch-reviews', (req, res) => {
    const { sku } = req.body;
    if (!sku) return res.status(400).json({ error: 'sku required' });
    const script = path.join(__dirname, 'fetch-jd.py');
    spawnPython(script, ['--sku', sku], res);
});

// ===== Fetch JD Store SKUs =====
app.post('/api/fetch-store-skus', (req, res) => {
    const { shopId, keyword, targetShop } = req.body;
    if (!shopId || !keyword) return res.status(400).json({ error: 'shopId and keyword required' });
    const script = path.join(__dirname, 'fetch-store-skus.py');
    const args = ['--shopId', shopId, '--keyword', keyword];
    if (targetShop) args.push('--targetShop', targetShop);
    spawnPython(script, args, res);
});

// ===== Fetch Douyin Store SKUs =====
app.post('/api/fetch-douyin-skus', (req, res) => {
    const { keyword, apifyToken, maxPages } = req.body;
    if (!keyword || !apifyToken) return res.status(400).json({ error: 'keyword and apifyToken required' });
    // Write config to temp file to avoid CLI encoding issues
    const tmpFile = path.join(require('os').tmpdir(), `dy_${Date.now()}.json`);
    fs.writeFileSync(tmpFile, JSON.stringify({ keyword, apifyToken, maxPages: maxPages || 10 }), 'utf-8');
    const script = path.join(__dirname, 'fetch-douyin-skus.py');
    spawnPython(script, ['--file', tmpFile], res, { PYTHONIOENCODING: 'utf-8' });
});

// ===== Fetch Tmall Store SKUs =====
app.post('/api/fetch-tmall-skus', (req, res) => {
    const { keyword, apifyToken, maxPages } = req.body;
    if (!keyword || !apifyToken) return res.status(400).json({ error: 'keyword and apifyToken required' });
    const tmpFile = path.join(require('os').tmpdir(), `tm_${Date.now()}.json`);
    fs.writeFileSync(tmpFile, JSON.stringify({ keyword, apifyToken, maxPages: maxPages || 3 }), 'utf-8');
    const script = path.join(__dirname, 'fetch-tmall-skus.py');
    spawnPython(script, ['--file', tmpFile], res, { PYTHONIOENCODING: 'utf-8' });
});

// ===== Fetch XHS Notes =====
app.post('/api/fetch-xhs-notes', (req, res) => {
    const { keyword, limit, profile } = req.body;
    if (!keyword) return res.status(400).json({ error: 'keyword required' });
    const script = path.join(__dirname, 'fetch-xhs.py');
    const args = ['--keyword', keyword, '--limit', String(limit || 20)];
    if (profile) args.push('--profile', profile);
    spawnPython(script, args, res);
});

// Start server
app.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
    console.log(`API Proxy: /api/proxy -> DeepSeek API`);
});
