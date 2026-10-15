// Minimal JSON logger that stamps the active trace/span id on every line,
// which is what lets Grafana jump from a Loki log line to the Jaeger trace.
const { trace } = require('@opentelemetry/api');

const service = process.env.OTEL_SERVICE_NAME || 'unknown';

function write(level, msg, fields = {}) {
  const line = { time: new Date().toISOString(), level, service, msg, ...fields };
  const span = trace.getActiveSpan();
  if (span) {
    const ctx = span.spanContext();
    line.trace_id = ctx.traceId;
    line.span_id = ctx.spanId;
  }
  console.log(JSON.stringify(line));
}

module.exports = {
  info: (msg, f) => write('info', msg, f),
  warn: (msg, f) => write('warn', msg, f),
  error: (msg, f) => write('error', msg, f),
};
