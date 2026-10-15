package com.ecommerce.orders;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

/** Moves an order to PAID / PAYMENT_FAILED when payment-service reports back. */
@Component
public class PaymentResultListener {

    private static final Logger log = LoggerFactory.getLogger(PaymentResultListener.class);

    private final JdbcTemplate jdbc;
    private final ObjectMapper json;

    public PaymentResultListener(JdbcTemplate jdbc, ObjectMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    @RabbitListener(queues = OrderServiceApplication.PAYMENT_RESULTS_QUEUE)
    public void onPaymentResult(Message message) throws Exception {
        String routingKey = message.getMessageProperties().getReceivedRoutingKey();
        JsonNode event = json.readTree(message.getBody());
        long orderId = event.get("orderId").asLong();
        String status = "payment.completed".equals(routingKey) ? "PAID" : "PAYMENT_FAILED";

        int updated = jdbc.update("UPDATE orders SET status = ?, updated_at = now() WHERE id = ?", status, orderId);
        if (updated == 0) {
            log.warn("payment result for unknown order {}", orderId);
        } else {
            log.info("order {} -> {}", orderId, status);
        }
    }
}
