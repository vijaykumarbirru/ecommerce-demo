package main

import (
	"context"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"
)

var logger = slog.New(slog.NewJSONHandler(os.Stdout, nil))

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// route maps a public /api/<prefix> path onto a backend service.
type route struct {
	prefix  string
	backend string
}

func proxyFor(backend string) *httputil.ReverseProxy {
	target, err := url.Parse(backend)
	if err != nil {
		panic(err)
	}
	return &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			r.SetURL(target)
			r.Out.URL.Path = strings.TrimPrefix(r.In.URL.Path, "/api")
			r.Out.URL.RawPath = ""
			r.Out.Host = target.Host
		},
		// otelhttp transport creates a client span and injects traceparent,
		// which is what stitches the gateway into the downstream trace.
		Transport: otelhttp.NewTransport(http.DefaultTransport),
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			logWithTrace(r.Context(), slog.LevelError, "upstream error", "backend", backend, "error", err.Error())
			http.Error(w, `{"error":"upstream unavailable"}`, http.StatusBadGateway)
		},
	}
}

func logWithTrace(ctx context.Context, level slog.Level, msg string, args ...any) {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		args = append(args, "trace_id", sc.TraceID().String(), "span_id", sc.SpanID().String())
	}
	logger.Log(ctx, level, msg, args...)
}

// accessLog runs inside the otelhttp handler, so the span is already active.
func accessLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		logWithTrace(r.Context(), slog.LevelInfo, "request",
			"method", r.Method, "path", r.URL.Path, "status", rec.status,
			"duration_ms", time.Since(start).Milliseconds())
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdown, err := setupTelemetry(ctx)
	if err != nil {
		logger.Error("telemetry setup failed", "error", err.Error())
		os.Exit(1)
	}

	routes := []route{
		{"/api/products", env("PRODUCT_SERVICE_URL", "http://product-service:8001")},
		{"/api/cart", env("CART_SERVICE_URL", "http://cart-service:8002")},
		{"/api/orders", env("ORDER_SERVICE_URL", "http://order-service:8003")},
		{"/api/payments", env("PAYMENT_SERVICE_URL", "http://payment-service:8004")},
		{"/api/inventory", env("INVENTORY_SERVICE_URL", "http://inventory-service:8006")},
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Write([]byte(`{"status":"ok"}`))
	})
	for _, rt := range routes {
		p := proxyFor(rt.backend)
		mux.Handle(rt.prefix, p)
		mux.Handle(rt.prefix+"/", p)
	}

	handler := otelhttp.NewHandler(accessLog(mux), "api-gateway",
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + spanRoute(r.URL.Path)
		}),
	)

	srv := &http.Server{Addr: ":" + env("PORT", "8000"), Handler: handler, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		logger.Info("api-gateway listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			logger.Error("server failed", "error", err.Error())
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	srv.Shutdown(shutCtx)
	shutdown(shutCtx)
}

// spanRoute keeps span names low-cardinality: /api/cart/user7/items -> /api/cart/{id}/items.
func spanRoute(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	for i := 2; i < len(parts); i++ {
		if parts[i] != "items" && parts[i] != "checkout" {
			parts[i] = "{id}"
		}
	}
	return "/" + strings.Join(parts, "/")
}
