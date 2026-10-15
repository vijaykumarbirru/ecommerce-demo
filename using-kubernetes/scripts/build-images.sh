#!/usr/bin/env bash
# Build every service image and load it into the kind cluster.
#   scripts/build-images.sh                      # all services
#   scripts/build-images.sh cart-service-node    # just one (source folder name)
# Works with macOS's built-in bash 3.2.
set -euo pipefail
cd "$(dirname "$0")/../services"
TAG="${TAG:-0.1.0}"
CLUSTER="${CLUSTER:-ecommerce}"

image_name() {   # source folder -> image name
  case "$1" in
    api-gateway-go) echo api-gateway ;;
    product-service-python) echo product-service ;;
    cart-service-node) echo cart-service ;;
    order-service-java) echo order-service ;;
    payment-service-dotnet) echo payment-service ;;
    inventory-service-node) echo inventory-service ;;
    notification-service-node) echo notification-service ;;
    frontend|loadgen) echo "$1" ;;
    *) echo "unknown service folder: $1" >&2; exit 1 ;;
  esac
}

if [ $# -gt 0 ]; then dirs=("$@"); else
  dirs=(api-gateway-go product-service-python cart-service-node order-service-java
        payment-service-dotnet inventory-service-node notification-service-node frontend loadgen)
fi
for d in "${dirs[@]}"; do
  img="ecommerce/$(image_name "$d"):${TAG}"
  echo ">> building $img from services/$d"
  docker build -q -t "$img" "$d" >/dev/null
  kind load docker-image "$img" --name "$CLUSTER" >/dev/null
  echo "   loaded into kind"
done
echo "done: ${#dirs[@]} image(s) built and loaded into kind cluster '$CLUSTER'"
