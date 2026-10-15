// Stock levels in Postgres. Reserves stock when a payment succeeds
// (consumes `payment.completed` from RabbitMQ) and exposes read-only HTTP.
const express = require('express');
const amqp = require('amqplib');
const { Pool } = require('pg');
const { trace, SpanStatusCode } = require('@opentelemetry/api');
const log = require('./log');

const PORT = process.env.PORT || 8006;
const RABBITMQ_URL = process.env.RABBITMQ_URL || 'amqp://guest:guest@rabbitmq:5672';
const EXCHANGE = process.env.RABBITMQ_EXCHANGE || 'ecommerce.events';
const QUEUE = 'inventory.payment-completed';
const RESTOCK_BELOW = 10;
const RESTOCK_TO = 100;

const pool = new Pool({
  host: process.env.POSTGRES_HOST || 'postgres',
  database: process.env.POSTGRES_DB || 'shop',
  user: process.env.POSTGRES_USER || 'postgres',
  password: process.env.POSTGRES_PASSWORD || 'postgres',
});

async function initDb() {
  await pool.query(`CREATE TABLE IF NOT EXISTS inventory (
    product_id TEXT PRIMARY KEY,
    stock INTEGER NOT NULL
  )`);
  for (let i = 1; i <= 8; i++) {
    await pool.query(
      'INSERT INTO inventory (product_id, stock) VALUES ($1, $2) ON CONFLICT DO NOTHING',
      [`p${i}`, RESTOCK_TO],
    );
  }
}

async function reserve(event) {
  const span = trace.getActiveSpan();
  for (const item of event.items || []) {
    const { rowCount } = await pool.query(
      'UPDATE inventory SET stock = stock - $2 WHERE product_id = $1 AND stock >= $2',
      [item.productId, item.quantity],
    );
    if (rowCount === 0) {
      log.error('insufficient stock', { orderId: event.orderId, productId: item.productId });
      span?.setStatus({ code: SpanStatusCode.ERROR, message: `insufficient stock for ${item.productId}` });
      continue;
    }
    // Keep the demo running forever: auto-restock when stock runs low.
    await pool.query('UPDATE inventory SET stock = $2 WHERE product_id = $1 AND stock < $3', [
      item.productId,
      RESTOCK_TO,
      RESTOCK_BELOW,
    ]);
  }
  log.info('stock reserved', { orderId: event.orderId, items: (event.items || []).length });
}

async function startConsumer() {
  for (;;) {
    try {
      const conn = await amqp.connect(RABBITMQ_URL);
      const ch = await conn.createChannel();
      await ch.assertExchange(EXCHANGE, 'topic', { durable: true });
      await ch.assertQueue(QUEUE, { durable: true });
      await ch.bindQueue(QUEUE, EXCHANGE, 'payment.completed');
      await ch.consume(QUEUE, async (msg) => {
        try {
          await reserve(JSON.parse(msg.content.toString()));
          ch.ack(msg);
        } catch (err) {
          log.error('failed to process payment.completed', { error: err.message });
          ch.nack(msg, false, false);
        }
      });
      conn.on('close', () => setTimeout(startConsumer, 2000));
      log.info(`consuming ${QUEUE}`);
      return;
    } catch (err) {
      log.warn('rabbitmq not ready, retrying', { error: err.message });
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
}

const app = express();
app.get('/health', (_req, res) => res.json({ status: 'ok' }));
app.get('/inventory', async (_req, res, next) => {
  try {
    const { rows } = await pool.query('SELECT product_id AS "productId", stock FROM inventory ORDER BY product_id');
    res.json(rows);
  } catch (err) {
    next(err);
  }
});
app.get('/inventory/:productId', async (req, res, next) => {
  try {
    const { rows } = await pool.query(
      'SELECT product_id AS "productId", stock FROM inventory WHERE product_id = $1',
      [req.params.productId],
    );
    if (rows.length === 0) return res.status(404).json({ error: 'unknown product' });
    res.json(rows[0]);
  } catch (err) {
    next(err);
  }
});
app.use((err, _req, res, _next) => {
  log.error('request failed', { error: err.message });
  res.status(500).json({ error: err.message });
});

initDb()
  .then(startConsumer)
  .then(() => app.listen(PORT, () => log.info(`inventory-service listening on ${PORT}`)))
  .catch((err) => {
    log.error('startup failed', { error: err.message });
    process.exit(1);
  });
