CREATE TABLE IF NOT EXISTS orders (
    id          BIGSERIAL PRIMARY KEY,
    user_id     TEXT           NOT NULL,
    total       NUMERIC(10, 2) NOT NULL,
    status      TEXT           NOT NULL,
    created_at  TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ    NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS order_items (
    order_id    BIGINT         NOT NULL REFERENCES orders (id),
    product_id  TEXT           NOT NULL,
    name        TEXT           NOT NULL,
    quantity    INTEGER        NOT NULL,
    price       NUMERIC(10, 2) NOT NULL
);
