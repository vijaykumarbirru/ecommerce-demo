package com.ecommerce.orders;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.core.MessageBuilder;
import org.springframework.amqp.core.MessageProperties;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/orders")
public class OrderController {

    private static final Logger log = LoggerFactory.getLogger(OrderController.class);

    public record Item(String productId, String name, int quantity, BigDecimal price) {}

    public record CreateOrder(String userId, List<Item> items) {}

    private final JdbcTemplate jdbc;
    private final RabbitTemplate rabbit;
    private final ObjectMapper json;
    private final String exchange;

    public OrderController(JdbcTemplate jdbc, RabbitTemplate rabbit, ObjectMapper json,
                           @Value("${app.exchange}") String exchange) {
        this.jdbc = jdbc;
        this.rabbit = rabbit;
        this.json = json;
        this.exchange = exchange;
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "ok");
    }

    @GetMapping
    public List<Map<String, Object>> recent(@RequestParam(defaultValue = "20") int limit) {
        return jdbc.queryForList(
                "SELECT id, user_id AS \"userId\", total, status, created_at AS \"createdAt\" "
                        + "FROM orders ORDER BY id DESC LIMIT ?", Math.min(limit, 100));
    }

    @GetMapping("/{id}")
    public ResponseEntity<Map<String, Object>> get(@PathVariable long id) {
        List<Map<String, Object>> rows = jdbc.queryForList(
                "SELECT id, user_id AS \"userId\", total, status, created_at AS \"createdAt\" FROM orders WHERE id = ?", id);
        if (rows.isEmpty()) {
            return ResponseEntity.notFound().build();
        }
        Map<String, Object> order = new LinkedHashMap<>(rows.get(0));
        order.put("items", jdbc.queryForList(
                "SELECT product_id AS \"productId\", name, quantity, price FROM order_items WHERE order_id = ?", id));
        return ResponseEntity.ok(order);
    }

    @PostMapping
    @Transactional
    public ResponseEntity<?> create(@RequestBody CreateOrder req) {
        if (req.userId() == null || req.items() == null || req.items().isEmpty()) {
            return ResponseEntity.badRequest().body(Map.of("error", "userId and items are required"));
        }
        BigDecimal total = req.items().stream()
                .map(i -> i.price().multiply(BigDecimal.valueOf(i.quantity())))
                .reduce(BigDecimal.ZERO, BigDecimal::add)
                .setScale(2, RoundingMode.HALF_UP);

        GeneratedKeyHolder keys = new GeneratedKeyHolder();
        jdbc.update(con -> {
            var ps = con.prepareStatement(
                    "INSERT INTO orders (user_id, total, status) VALUES (?, ?, 'PENDING_PAYMENT')",
                    new String[] {"id"});
            ps.setString(1, req.userId());
            ps.setBigDecimal(2, total);
            return ps;
        }, keys);
        long orderId = keys.getKey().longValue();

        for (Item i : req.items()) {
            jdbc.update("INSERT INTO order_items (order_id, product_id, name, quantity, price) VALUES (?, ?, ?, ?, ?)",
                    orderId, i.productId(), i.name(), i.quantity(), i.price());
        }

        Map<String, Object> event = Map.of(
                "orderId", orderId, "userId", req.userId(), "total", total, "items", req.items());
        // Publish only after the order row is committed, so a fast payment
        // result can never race ahead of the INSERT it needs to update.
        TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
            @Override
            public void afterCommit() {
                publish("order.created", event);
            }
        });
        log.info("order {} created for {} total={}", orderId, req.userId(), total);

        return ResponseEntity.status(HttpStatus.CREATED).body(Map.of(
                "id", orderId, "userId", req.userId(), "total", total, "status", "PENDING_PAYMENT"));
    }

    private void publish(String routingKey, Object payload) {
        // Plain JSON body (no Java type headers) so the .NET and Node
        // consumers can read it. The OTel agent injects traceparent headers.
        byte[] body;
        try {
            body = json.writeValueAsBytes(payload);
        } catch (Exception e) {
            throw new IllegalStateException("cannot serialize event", e);
        }
        var message = MessageBuilder.withBody(body)
                .setContentType(MessageProperties.CONTENT_TYPE_JSON)
                .build();
        rabbit.send(exchange, routingKey, message);
    }
}
