using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace PaymentService;

/// <summary>Custom spans and business metrics for the payment flow.</summary>
public static class Telemetry
{
    public const string Name = "payment-service";

    public static readonly ActivitySource Source = new(Name);

    private static readonly Meter Meter = new(Name);

    public static readonly Counter<long> PaymentsProcessed =
        Meter.CreateCounter<long>("payments_processed", description: "Payments processed, by result");

    public static readonly Histogram<double> PaymentAmount =
        Meter.CreateHistogram<double>("payment_amount", unit: "USD", description: "Amount per payment attempt");
}
