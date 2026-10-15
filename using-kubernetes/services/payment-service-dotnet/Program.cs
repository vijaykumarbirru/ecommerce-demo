using Npgsql;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using PaymentService;

var builder = WebApplication.CreateBuilder(args);
var cfg = builder.Configuration;

// JSON console logs with TraceId/SpanId attached, for Loki -> Jaeger links.
builder.Logging.ClearProviders();
builder.Logging.AddJsonConsole(o => o.IncludeScopes = true);
builder.Logging.Configure(o => o.ActivityTrackingOptions =
    ActivityTrackingOptions.TraceId | ActivityTrackingOptions.SpanId);

var connString =
    $"Host={cfg["POSTGRES_HOST"] ?? "postgres"};Database={cfg["POSTGRES_DB"] ?? "shop"};" +
    $"Username={cfg["POSTGRES_USER"] ?? "postgres"};Password={cfg["POSTGRES_PASSWORD"] ?? "postgres"}";
builder.Services.AddSingleton(NpgsqlDataSource.Create(connString));
builder.Services.AddHostedService<PaymentConsumer>();

// The SDK is wired by hand here (no auto-instrumentation agent). The OTLP
// exporter reads OTEL_EXPORTER_OTLP_ENDPOINT / OTEL_SERVICE_NAME from env.
builder.Services.AddOpenTelemetry()
    .ConfigureResource(r => r.AddService(Telemetry.Name))
    .WithTracing(t => t
        .AddSource(Telemetry.Name)
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddNpgsql()
        .AddOtlpExporter())
    .WithMetrics(m => m
        .AddMeter(Telemetry.Name)
        .AddAspNetCoreInstrumentation()
        .AddRuntimeInstrumentation()
        .AddOtlpExporter());

var app = builder.Build();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapGet("/payments", async (NpgsqlDataSource db) =>
{
    await using var cmd = db.CreateCommand(
        "SELECT id, order_id, amount, status, created_at FROM payments ORDER BY id DESC LIMIT 20");
    await using var reader = await cmd.ExecuteReaderAsync();
    var rows = new List<object>();
    while (await reader.ReadAsync())
    {
        rows.Add(new
        {
            id = reader.GetInt64(0),
            orderId = reader.GetInt64(1),
            amount = reader.GetDecimal(2),
            status = reader.GetString(3),
            createdAt = reader.GetDateTime(4),
        });
    }
    return Results.Ok(rows);
});

app.Run($"http://0.0.0.0:{cfg["PORT"] ?? "8004"}");
