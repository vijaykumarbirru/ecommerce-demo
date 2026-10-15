// Listens to every order/payment event and "sends" a notification (logs it).
// The amqplib auto-instrumentation continues the trace from the publisher.
const express = require('express');
const amqp = require('amqplib');
const { metrics } = require('@opentelemetry/api');
const log = require('./log');

const PORT = process.env.PORT || 8005;
const RABBITMQ_URL = process.env.RABBITMQ_URL || 'amqp://guest:guest@rabbitmq:5672';
const EXCHANGE = process.env.RABBITMQ_EXCHANGE || 'ecommerce.events';
const QUEUE = 'notification.all-events';

const sent = metrics.getMeter('notification-service').createCounter('notifications_sent', {
  description: 'Notifications sent by event type',
});

const TEMPLATES = {
  'order.created': (e) => `Order #${e.orderId} received, total $${e.total}`,
  'payment.completed': (e) => `Payment for order #${e.orderId} succeeded`,
  'payment.failed': (e) => `Payment for order #${e.orderId} was declined: ${e.reason}`,
};

async function startConsumer() {
  for (;;) {
    try {
      const conn = await amqp.connect(RABBITMQ_URL);
      const ch = await conn.createChannel();
      await ch.assertExchange(EXCHANGE, 'topic', { durable: true });
      await ch.assertQueue(QUEUE, { durable: true });
      await ch.bindQueue(QUEUE, EXCHANGE, 'order.*');
      await ch.bindQueue(QUEUE, EXCHANGE, 'payment.*');
      await ch.consume(QUEUE, (msg) => {
        const type = msg.fields.routingKey;
        try {
          const event = JSON.parse(msg.content.toString());
          const text = (TEMPLATES[type] || (() => `Event ${type}`))(event);
          log.info('notification sent', { type, userId: event.userId, text });
          sent.add(1, { event_type: type });
          ch.ack(msg);
        } catch (err) {
          log.error('bad event payload', { type, error: err.message });
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

startConsumer().then(() => app.listen(PORT, () => log.info(`notification-service listening on ${PORT}`)));
