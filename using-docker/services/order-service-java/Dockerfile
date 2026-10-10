FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /src
COPY pom.xml .
RUN mvn -q dependency:go-offline
COPY src ./src
RUN mvn -q package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
# Zero-code instrumentation: the OTel Java agent instruments Spring MVC,
# JDBC, RabbitMQ and logging, configured entirely by OTEL_* env vars.
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.9.0/opentelemetry-javaagent.jar /app/opentelemetry-javaagent.jar
COPY --from=build /src/target/order-service.jar /app/order-service.jar
EXPOSE 8003
ENTRYPOINT ["java", "-javaagent:/app/opentelemetry-javaagent.jar", "-XX:MaxRAMPercentage=75", "-jar", "/app/order-service.jar"]
