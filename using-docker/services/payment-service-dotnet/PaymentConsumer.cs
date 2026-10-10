using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Npgsql;
using OpenTelemetry;
using OpenTelemetry.Context.Propagation;
using OpenTelemetry.Trace;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace PaymentService;

/// <summary>
/// Consumes order.created, simulates a card charge (~15% declined), stores the
/// result and publishes payment.completed / payment.failed.
///
/// RabbitMQ.Client 6.x has no OpenTelemetry instrumentation, so the W3C
/// trace context is extracted from / injected into message headers by hand.
/// This is what keeps one trace across Java -> .NET -> Java/Node.
/// </summary>
public sealed class PaymentConsumer(
    NpgsqlDataSource db,
    IConfiguration config,
    ILogger<PaymentConsumer> log) : BackgroundService
{
    private const string Queue = "payment.order-created";
    private static readonly TextMapPropagator Propagator = Propagators.DefaultTextMapPropagator;

    private readonly string _exchange = config["RABBITMQ_EXCHANGE"] ?? "ecommerce.events";
    private readonly double _declineRate = double.Parse(config["DECLINE_RATE"] ?? "0.15");
    private readonly object _publishLock = new();
    private IConnection? _connection;
    private IModel? _channel;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await EnsureSchema(stoppingToken);

        var factory = new ConnectionFactory
        {
            Uri = new Uri(config["RABBITMQ_URL"] ?? "amqp://guest:guest@rabbitmq:5672"),
            DispatchConsumersAsync = true,
            AutomaticRecoveryEnabled = true,
        };

        while (!stoppingToken.IsCancellationRequested && _connection is null)
        {
            try
            {
                _connection = factory.CreateConnection("payment-service");
            }
            catch (Exception ex)
            {
                log.LogWarning("RabbitMQ not ready ({Message}), retrying", ex.Message);
                await Task.Delay(3000, stoppingToken);
            }
        }

        _channel = _connection!.CreateModel();
        _channel.ExchangeDeclare(_exchange, ExchangeType.Topic, durable: true);
        _channel.QueueDeclare(Queue, durable: true, exclusive: false, autoDelete: false);
        _channel.QueueBind(Queue, _exchange, "order.created");
        _channel.BasicQos(0, 10, false);

        var consumer = new AsyncEventingBasicConsumer(_channel);
        consumer.Received += (_, ea) => Handle(ea);
        _channel.BasicConsume(Queue, autoAck: false, consumer);
        log.LogInformation("Consuming {Queue}", Queue);

        await Task.Delay(Timeout.Infinite, stoppingToken).ContinueWith(_ => { });
    }

    private async Task Handle(BasicDeliverEventArgs ea)
    {
        var parent = Propagator.Extract(default, ea.BasicProperties, ReadHeader);
        Baggage.Current = parent.Baggage;

        using var activity = Telemetry.Source.StartActivity(
            $"{Queue} process", ActivityKind.Consumer, parent.ActivityContext);
        activity?.SetTag("messaging.system", "rabbitmq");
        activity?.SetTag("messaging.destination.name", _exchange);
        activity?.SetTag("messaging.rabbitmq.destination.routing_key", ea.RoutingKey);

        try
        {
            var order = JsonNode.Parse(Encoding.UTF8.GetString(ea.Body.Span))!;
            var orderId = order["orderId"]!.GetValue<long>();
            var amount = order["total"]!.GetValue<decimal>();
            activity?.SetTag("order.id", orderId);

            // Simulate the call to a card processor.
            await Task.Delay(Random.Shared.Next(50, 300));
            var declined = Random.Shared.NextDouble() < _declineRate;
            var status = declined ? "DECLINED" : "CAPTURED";

            await using (var cmd = db.CreateCommand(
                "INSERT INTO payments (order_id, amount, status) VALUES ($1, $2, $3)"))
            {
                cmd.Parameters.AddWithValue(orderId);
                cmd.Parameters.AddWithValue(amount);
                cmd.Parameters.AddWithValue(status);
                await cmd.ExecuteNonQueryAsync();
            }

            Telemetry.PaymentsProcessed.Add(1, new KeyValuePair<string, object?>("result", status.ToLowerInvariant()));
            Telemetry.PaymentAmount.Record((double)amount);

            var result = new JsonObject
            {
                ["orderId"] = orderId,
                ["userId"] = order["userId"]?.GetValue<string>(),
                ["amount"] = amount,
                ["items"] = order["items"]?.DeepClone(),
            };
            if (declined)
            {
                // A business decline, not a technical failure: the span stays OK.
                result["reason"] = "card declined by issuer";
                log.LogWarning("Payment declined for order {OrderId} amount {Amount}", orderId, amount);
                Publish("payment.failed", result);
            }
            else
            {
                log.LogInformation("Payment captured for order {OrderId} amount {Amount}", orderId, amount);
                Publish("payment.completed", result);
            }

            _channel!.BasicAck(ea.DeliveryTag, multiple: false);
        }
        catch (Exception ex)
        {
            activity?.SetStatus(ActivityStatusCode.Error, ex.Message);
            activity?.AddException(ex);
            log.LogError(ex, "Failed to process payment message");
            _channel!.BasicNack(ea.DeliveryTag, multiple: false, requeue: false);
        }
    }

    private void Publish(string routingKey, JsonObject payload)
    {
        using var activity = Telemetry.Source.StartActivity($"{routingKey} publish", ActivityKind.Producer);
        activity?.SetTag("messaging.system", "rabbitmq");
        activity?.SetTag("messaging.destination.name", _exchange);
        activity?.SetTag("messaging.rabbitmq.destination.routing_key", routingKey);

        lock (_publishLock)
        {
            var props = _channel!.CreateBasicProperties();
            props.ContentType = "application/json";
            props.DeliveryMode = 2;
            props.Headers = new Dictionary<string, object>();
            var ctx = activity?.Context ?? Activity.Current?.Context ?? default;
            Propagator.Inject(new PropagationContext(ctx, Baggage.Current), props,
                (p, key, value) => p.Headers[key] = value);

            _channel.BasicPublish(_exchange, routingKey, props,
                Encoding.UTF8.GetBytes(payload.ToJsonString()));
        }
    }

    private static IEnumerable<string> ReadHeader(IBasicProperties props, string key)
    {
        if (props.Headers is not null && props.Headers.TryGetValue(key, out var value))
        {
            // Header values arrive as byte[] from the AMQP wire format.
            return [value is byte[] bytes ? Encoding.UTF8.GetString(bytes) : value?.ToString() ?? ""];
        }
        return [];
    }

    private async Task EnsureSchema(CancellationToken ct)
    {
        await using var cmd = db.CreateCommand("""
            CREATE TABLE IF NOT EXISTS payments (
                id         BIGSERIAL PRIMARY KEY,
                order_id   BIGINT         NOT NULL,
                amount     NUMERIC(10, 2) NOT NULL,
                status     TEXT           NOT NULL,
                created_at TIMESTAMPTZ    NOT NULL DEFAULT now()
            )
            """);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    public override void Dispose()
    {
        _channel?.Close();
        _connection?.Close();
        base.Dispose();
    }
}
