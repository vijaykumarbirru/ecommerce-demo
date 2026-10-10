// Shopping cart stored in Redis (one hash per user). Checkout hands the cart
// to order-service over HTTP, which continues the same distributed trace.
const express = require('express');
const axios = require('axios');
const Redis = require('ioredis');
const { metrics } = require('@opentelemetry/api');
const log = require('./log');

const PORT = process.env.PORT || 8002;
const PRODUCT_SERVICE_URL = process.env.PRODUCT_SERVICE_URL || 'http://product-service:8001';
const ORDER_SERVICE_URL = process.env.ORDER_SERVICE_URL || 'http://order-service:8003';

const redis = new Redis(process.env.REDIS_URL || 'redis://redis:6379');
const meter = metrics.getMeter('cart-service');
const itemsAdded = meter.createCounter('cart_items_added', { description: 'Items added to carts' });
const checkouts = meter.createCounter('cart_checkouts', { description: 'Checkout attempts by result' });

const app = express();
app.use(express.json());

const key = (userId) => `cart:${userId}`;

async function readCart(userId) {
  const raw = await redis.hgetall(key(userId));
  const items = Object.values(raw).map((v) => JSON.parse(v));
  const total = items.reduce((sum, i) => sum + i.price * i.quantity, 0);
  return { userId, items, total: Math.round(total * 100) / 100 };
}

app.get('/health', (_req, res) => res.json({ status: 'ok' }));

app.get('/cart/:userId', async (req, res, next) => {
  try {
    res.json(await readCart(req.params.userId));
  } catch (err) {
    next(err);
  }
});

app.post('/cart/:userId/items', async (req, res, next) => {
  const { productId, quantity = 1 } = req.body || {};
  if (!productId) return res.status(400).json({ error: 'productId is required' });
  try {
    // Price comes from the catalog, never from the client.
    const { data: product } = await axios.get(`${PRODUCT_SERVICE_URL}/products/${productId}`);
    const existing = await redis.hget(key(req.params.userId), productId);
    const qty = (existing ? JSON.parse(existing).quantity : 0) + Number(quantity);
    const item = { productId, name: product.name, price: product.price, quantity: qty };
    await redis.hset(key(req.params.userId), productId, JSON.stringify(item));
    await redis.expire(key(req.params.userId), 3600);
    itemsAdded.add(Number(quantity), { product_id: productId });
    log.info('item added to cart', { userId: req.params.userId, productId, quantity: qty });
    res.status(201).json(await readCart(req.params.userId));
  } catch (err) {
    if (err.response && err.response.status === 404) {
      log.warn('add to cart for unknown product', { productId });
      return res.status(404).json({ error: 'product not found' });
    }
    next(err);
  }
});

// Set an item's quantity outright (0 removes it).
app.put('/cart/:userId/items/:productId', async (req, res, next) => {
  const { userId, productId } = req.params;
  const quantity = Number((req.body || {}).quantity);
  if (!Number.isInteger(quantity) || quantity < 0) {
    return res.status(400).json({ error: 'quantity must be a non-negative integer' });
  }
  try {
    const existing = await redis.hget(key(userId), productId);
    if (!existing) return res.status(404).json({ error: 'item not in cart' });
    if (quantity === 0) {
      await redis.hdel(key(userId), productId);
    } else {
      await redis.hset(key(userId), productId, JSON.stringify({ ...JSON.parse(existing), quantity }));
    }
    log.info('cart item updated', { userId, productId, quantity });
    res.json(await readCart(userId));
  } catch (err) {
    next(err);
  }
});

app.delete('/cart/:userId/items/:productId', async (req, res, next) => {
  try {
    await redis.hdel(key(req.params.userId), req.params.productId);
    res.json(await readCart(req.params.userId));
  } catch (err) {
    next(err);
  }
});

app.delete('/cart/:userId', async (req, res, next) => {
  try {
    await redis.del(key(req.params.userId));
    res.status(204).end();
  } catch (err) {
    next(err);
  }
});

app.post('/cart/:userId/checkout', async (req, res, next) => {
  const { userId } = req.params;
  try {
    const cart = await readCart(userId);
    if (cart.items.length === 0) {
      checkouts.add(1, { result: 'empty' });
      return res.status(400).json({ error: 'cart is empty' });
    }
    const { data: order } = await axios.post(`${ORDER_SERVICE_URL}/orders`, {
      userId,
      items: cart.items,
    });
    await redis.del(key(userId));
    checkouts.add(1, { result: 'ok' });
    log.info('checkout complete', { userId, orderId: order.id, total: order.total });
    res.status(201).json(order);
  } catch (err) {
    checkouts.add(1, { result: 'error' });
    next(err);
  }
});

app.use((err, _req, res, _next) => {
  log.error('request failed', { error: err.message });
  res.status(502).json({ error: err.message });
});

app.listen(PORT, () => log.info(`cart-service listening on ${PORT}`));
