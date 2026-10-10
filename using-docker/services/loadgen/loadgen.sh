#!/bin/sh
# Simulated shoppers so dashboards and traces always have live data.
# Each loop: browse catalog -> add 1-3 items -> (sometimes) an unknown
# product (404) -> checkout. Tune pace with LOADGEN_SLEEP.
GW="${GATEWAY_URL:-http://api-gateway:8000}"
SLEEP="${LOADGEN_SLEEP:-1}"

echo "loadgen: waiting for $GW"
until curl -sf "$GW/healthz" >/dev/null; do sleep 2; done
echo "loadgen: started"

while true; do
  user="shopper$((RANDOM % 25))"
  curl -s -o /dev/null "$GW/api/products"

  n=$((RANDOM % 3 + 1))
  i=0
  while [ $i -lt $n ]; do
    pid="p$((RANDOM % 8 + 1))"
    curl -s -o /dev/null -X POST -H 'content-type: application/json' \
      -d "{\"productId\":\"$pid\",\"quantity\":$((RANDOM % 3 + 1))}" \
      "$GW/api/cart/$user/items"
    i=$((i + 1))
  done

  # ~5% of shoppers try a product that doesn't exist.
  if [ $((RANDOM % 20)) -eq 0 ]; then
    curl -s -o /dev/null -X POST -H 'content-type: application/json' \
      -d '{"productId":"p404","quantity":1}' "$GW/api/cart/$user/items"
  fi

  curl -s -o /dev/null "$GW/api/cart/$user"
  curl -s -o /dev/null -X POST "$GW/api/cart/$user/checkout"
  curl -s -o /dev/null "$GW/api/orders?limit=5"

  sleep "$SLEEP"
done
