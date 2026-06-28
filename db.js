// db.js — SQLite database for review-insight (replaces browser localStorage)
const Database = require('better-sqlite3');
const path = require('path');

const DB_PATH = path.join(process.env.DATA_DIR || path.join(__dirname, 'data'), 'review-insight.db');

// Ensure data directory exists
require('fs').mkdirSync(path.dirname(DB_PATH), { recursive: true });

const db = new Database(DB_PATH);

// Enable WAL mode for better concurrent read performance
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

// --- Schema ---
db.exec(`
  CREATE TABLE IF NOT EXISTS user_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),  -- single-user for now
    api_key TEXT DEFAULT '',
    apify_token TEXT DEFAULT '',
    model TEXT DEFAULT 'deepseek-chat',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS review_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    product_name TEXT DEFAULT '',
    review_count INTEGER DEFAULT 0,
    report_text TEXT DEFAULT '',
    reviews_json TEXT DEFAULT '',
    stats_json TEXT DEFAULT '',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS strategy_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    platform TEXT DEFAULT '',
    shop_name TEXT DEFAULT '',
    shop_id TEXT DEFAULT '',
    total_skus INTEGER DEFAULT 0,
    family_count INTEGER DEFAULT 0,
    report_text TEXT DEFAULT '',
    skus_json TEXT DEFAULT '',
    platform_key TEXT DEFAULT 'jd',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS trend_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    keyword TEXT DEFAULT '',
    total_notes INTEGER DEFAULT 0,
    report_text TEXT DEFAULT '',
    notes_json TEXT DEFAULT '',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  -- Ensure single user row exists
  INSERT OR IGNORE INTO user_settings (id) VALUES (1);
`);

// --- User Settings ---
function getSettings() {
  return db.prepare('SELECT * FROM user_settings WHERE id = 1').get();
}

function saveSettings(settings) {
  const { api_key, apify_token, model } = settings;
  db.prepare(`UPDATE user_settings SET api_key = ?, apify_token = ?, model = ?, updated_at = CURRENT_TIMESTAMP WHERE id = 1`)
    .run(api_key || '', apify_token || '', model || 'deepseek-chat');
  return getSettings();
}

// --- Review Reports ---
function listReviewReports(limit = 50) {
  return db.prepare('SELECT id, product_name, review_count, stats_json, created_at FROM review_reports ORDER BY id DESC LIMIT ?').all(limit);
}

function getReviewReport(id) {
  return db.prepare('SELECT * FROM review_reports WHERE id = ?').get(id);
}

function saveReviewReport(data) {
  const { product_name, review_count, report_text, reviews_json, stats_json } = data;
  const result = db.prepare(
    'INSERT INTO review_reports (product_name, review_count, report_text, reviews_json, stats_json) VALUES (?, ?, ?, ?, ?)'
  ).run(product_name || '', review_count || 0, report_text || '', reviews_json || '[]', stats_json || '{}');
  // Keep only latest 50
  db.prepare('DELETE FROM review_reports WHERE id NOT IN (SELECT id FROM review_reports ORDER BY id DESC LIMIT 50)').run();
  return { id: result.lastInsertRowid };
}

function deleteReviewReport(id) {
  db.prepare('DELETE FROM review_reports WHERE id = ?').run(id);
}

// --- Strategy Reports ---
function listStrategyReports(limit = 50) {
  return db.prepare('SELECT id, platform, shop_name, shop_id, total_skus, family_count, platform_key, created_at FROM strategy_reports ORDER BY id DESC LIMIT ?').all(limit);
}

function getStrategyReport(id) {
  return db.prepare('SELECT * FROM strategy_reports WHERE id = ?').get(id);
}

function saveStrategyReport(data) {
  const { platform, shop_name, shop_id, total_skus, family_count, report_text, skus_json, platform_key } = data;
  const result = db.prepare(
    'INSERT INTO strategy_reports (platform, shop_name, shop_id, total_skus, family_count, report_text, skus_json, platform_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?)'
  ).run(platform || '', shop_name || '', shop_id || '', total_skus || 0, family_count || 0, report_text || '', skus_json || '[]', platform_key || 'jd');
  // Keep only latest 50
  db.prepare('DELETE FROM strategy_reports WHERE id NOT IN (SELECT id FROM strategy_reports ORDER BY id DESC LIMIT 50)').run();
  return { id: result.lastInsertRowid };
}

function deleteStrategyReport(id) {
  db.prepare('DELETE FROM strategy_reports WHERE id = ?').run(id);
}

// --- Trend Reports ---
function listTrendReports(limit = 50) {
  return db.prepare('SELECT id, keyword, total_notes, created_at FROM trend_reports ORDER BY id DESC LIMIT ?').all(limit);
}

function getTrendReport(id) {
  return db.prepare('SELECT * FROM trend_reports WHERE id = ?').get(id);
}

function saveTrendReport(data) {
  const { keyword, total_notes, report_text, notes_json } = data;
  const result = db.prepare(
    'INSERT INTO trend_reports (keyword, total_notes, report_text, notes_json) VALUES (?, ?, ?, ?)'
  ).run(keyword || '', total_notes || 0, report_text || '', notes_json || '[]');
  db.prepare('DELETE FROM trend_reports WHERE id NOT IN (SELECT id FROM trend_reports ORDER BY id DESC LIMIT 50)').run();
  return { id: result.lastInsertRowid };
}

function deleteTrendReport(id) {
  db.prepare('DELETE FROM trend_reports WHERE id = ?').run(id);
}

module.exports = {
  getSettings, saveSettings,
  listReviewReports, getReviewReport, saveReviewReport, deleteReviewReport,
  listStrategyReports, getStrategyReport, saveStrategyReport, deleteStrategyReport,
  listTrendReports, getTrendReport, saveTrendReport, deleteTrendReport,
};
