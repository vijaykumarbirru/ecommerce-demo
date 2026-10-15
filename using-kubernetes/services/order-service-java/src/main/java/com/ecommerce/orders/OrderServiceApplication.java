package com.ecommerce.orders;

import org.springframework.amqp.core.Binding;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Bean;

@SpringBootApplication
public class OrderServiceApplication {

    public static final String PAYMENT_RESULTS_QUEUE = "order.payment-results";

    public static void main(String[] args) {
        SpringApplication.run(OrderServiceApplication.class, args);
    }

    @Bean
    TopicExchange eventsExchange(@Value("${app.exchange}") String exchange) {
        return new TopicExchange(exchange, true, false);
    }

    @Bean
    Queue paymentResultsQueue() {
        return new Queue(PAYMENT_RESULTS_QUEUE, true);
    }

    @Bean
    Binding paymentResultsBinding(Queue paymentResultsQueue, TopicExchange eventsExchange) {
        return BindingBuilder.bind(paymentResultsQueue).to(eventsExchange).with("payment.*");
    }
}
