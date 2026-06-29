// Product Insight Analysis System - Node.js Server
// Replaces serve.ps1 for cross-platform deployment
const express = require('express');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const db = require('./db');
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

        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 600000); // 10 min timeout
        console.log('[API] -> ' + provider + ' stream=' + (req.body.stream || false) + ' body=' + JSON.stringify(req.body).length + ' chars');

        const fetchResp = await fetch(apiUrl, {
            method: 'POST', headers,
            body: JSON.stringify(req.body),
            signal: controller.signal,
        });
        clearTimeout(timeoutId);

        console.log('[API] <- ' + provider + ' status=' + fetchResp.status);

        if (!fetchResp.ok) {
            const err = await fetchResp.text();
            console.log('[API] <- ERROR: ' + err.substring(0, 200));
            return res.status(fetchResp.status).send(err);
        }

        // Stream response back (disable timeout for long-running AI analysis)
        res.setTimeout(0);
        res.setHeader('Content-Type', fetchResp.headers.get('content-type') || 'application/json');
        res.flushHeaders();
        const reader = fetchResp.body.getReader();
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            res.write(Buffer.from(value));
        }
        console.log('[API] stream complete');
        res.end();
    } catch (e) {
        console.log('[API] ERROR: ' + e.message);
        if (!res.headersSent) res.status(502).json({ error: e.message });
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
    res.flushHeaders();  // Ensure headers sent immediately
    res.setTimeout(0);   // Disable timeout for long-running requests

    const env = { ...process.env, PYTHONUNBUFFERED: '1', PYTHONIOENCODING: 'utf-8', ...envVars };
    const py = spawn(process.env.PYTHON_BIN || 'python', [script, ...args], { env });

    console.log(`[${path.basename(script)}] Started with args:`, args);

    let _stdoutBuffer = '';
    py.stdout.on('data', (data) => {
        _stdoutBuffer += data.toString().replace(/\r/g, '');
        const lines = _stdoutBuffer.split('\n');
        _stdoutBuffer = lines.pop() || '';  // Keep incomplete last line in buffer
        for (const line of lines) {
            if (!line.trim()) continue;
            if (line.startsWith('STATUS:')) {
                try {
                    const obj = JSON.parse(line.substring(7));
                    obj.type = 'progress';
                    const sse = `data: ${JSON.stringify(obj)}\n\n`;
                    console.log(`[SSE] STATUS: ${line.substring(7, 80)}`);
                    res.write(sse);
                } catch(e) { console.log('[SSE] Parse error:', e.message); }
            } else if (line.startsWith('DATA:')) {
                try {
                    const obj = JSON.parse(line.substring(5));
                    obj.type = 'result';
                    const sse = `data: ${JSON.stringify(obj)}\n\n`;
                    console.log(`[SSE] DATA (${line.length} chars)`);
                    res.write(sse);
                    res.end();
                    py.kill();
                    return;
                } catch(e) { console.log('[SSE] DATA parse error:', e.message); }
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

// ===== Data API (SQLite replaces browser localStorage) =====

// Settings
app.get('/api/settings', (req, res) => res.json(db.getSettings()));
app.post('/api/settings', (req, res) => {
    const updated = db.saveSettings({
        api_key: req.body.apiKey || '',
        apify_token: req.body.apifyToken || '',
        model: req.body.model || 'deepseek-chat',
    });
    res.json(updated);
});

// Review reports
app.get('/api/reports', (req, res) => res.json(db.listReviewReports()));
app.get('/api/reports/:id', (req, res) => {
    const r = db.getReviewReport(req.params.id);
    r ? res.json(r) : res.status(404).json({ error: 'Not found' });
});
app.post('/api/reports', (req, res) => {
    const result = db.saveReviewReport({
        product_name: req.body.productName || '',
        review_count: req.body.reviewCount || 0,
        report_text: req.body.report || '',
        reviews_json: JSON.stringify(req.body.reviews || []),
        stats_json: JSON.stringify(req.body.stats || null),
    });
    res.json(result);
});
app.delete('/api/reports/:id', (req, res) => {
    db.deleteReviewReport(req.params.id);
    res.json({ ok: true });
});

// Strategy reports
app.get('/api/strategy-reports', (req, res) => res.json(db.listStrategyReports()));
app.get('/api/strategy-reports/:id', (req, res) => {
    const r = db.getStrategyReport(req.params.id);
    r ? res.json(r) : res.status(404).json({ error: 'Not found' });
});
app.post('/api/strategy-reports', (req, res) => {
    const result = db.saveStrategyReport({
        platform: req.body.platform || '',
        shop_name: req.body.shopName || '',
        shop_id: req.body.shopId || '',
        total_skus: req.body.totalSkus || 0,
        family_count: req.body.familyCount || 0,
        report_text: req.body.report || '',
        skus_json: JSON.stringify(req.body.skus || []),
        platform_key: req.body.platformKey || 'jd',
    });
    res.json(result);
});
app.delete('/api/strategy-reports/:id', (req, res) => {
    db.deleteStrategyReport(req.params.id);
    res.json({ ok: true });
});

// Trend reports
app.get('/api/trend-reports', (req, res) => res.json(db.listTrendReports()));
app.get('/api/trend-reports/:id', (req, res) => {
    const r = db.getTrendReport(req.params.id);
    r ? res.json(r) : res.status(404).json({ error: 'Not found' });
});
app.post('/api/trend-reports', (req, res) => {
    const result = db.saveTrendReport({
        keyword: req.body.keyword || '',
        total_notes: req.body.totalNotes || 0,
        report_text: req.body.report || '',
        notes_json: JSON.stringify(req.body.notes || []),
    });
    res.json(result);
});
app.delete('/api/trend-reports/:id', (req, res) => {
    db.deleteTrendReport(req.params.id);
    res.json({ ok: true });
});

// Start server
app.listen(PORT, '0.0.0.0', () => {
    console.log(`Server running on http://localhost:${PORT}`);
    console.log(`  Data API: /api/reports, /api/strategy-reports, /api/trend-reports`);
    console.log(`  Data file: ${path.join(__dirname, 'data', 'review-insight.db')}`);
});
