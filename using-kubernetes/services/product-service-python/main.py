"""Product catalog backed by MongoDB.

Instrumented with zero code changes: the container runs under
`opentelemetry-instrument`, which auto-instruments FastAPI and PyMongo and
(with OTEL_PYTHON_LOG_CORRELATION=true) adds trace_id to every log line.
"""
import logging
import os
import random
import time

from fastapi import FastAPI, HTTPException
from pymongo import MongoClient

log = logging.getLogger("product-service")

# Chaos knobs so the dashboards have something interesting to show.
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.02"))
SLOW_RATE = float(os.getenv("SLOW_RATE", "0.03"))

SEED = [
    {"_id": "p1", "name": "Mechanical Keyboard", "price": 89.99, "category": "electronics"},
    {"_id": "p2", "name": "Wireless Mouse", "price": 29.99, "category": "electronics"},
    {"_id": "p3", "name": "27in Monitor", "price": 249.00, "category": "electronics"},
    {"_id": "p4", "name": "USB-C Hub", "price": 39.50, "category": "accessories"},
    {"_id": "p5", "name": "Laptop Stand", "price": 45.00, "category": "accessories"},
    {"_id": "p6", "name": "Noise-Cancelling Headphones", "price": 199.00, "category": "audio"},
    {"_id": "p7", "name": "Webcam 1080p", "price": 59.99, "category": "electronics"},
    {"_id": "p8", "name": "Desk Lamp", "price": 24.99, "category": "home"},
]

client = MongoClient(os.getenv("MONGO_URI", "mongodb://mongodb:27017"))
products = client[os.getenv("MONGO_DB", "catalog")]["products"]

app = FastAPI(title="product-service")


@app.on_event("startup")
def seed() -> None:
    for p in SEED:
        products.update_one({"_id": p["_id"]}, {"$setOnInsert": p}, upsert=True)
    log.info("catalog seeded with %d products", len(SEED))


def _chaos() -> None:
    if random.random() < SLOW_RATE:
        delay = random.uniform(0.8, 2.0)
        log.warning("injecting slow response of %.2fs", delay)
        time.sleep(delay)
    if random.random() < ERROR_RATE:
        log.error("injected failure while reading catalog")
        raise HTTPException(status_code=500, detail="catalog read failed")


def _out(doc: dict) -> dict:
    doc["id"] = doc.pop("_id")
    return doc


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/products")
def list_products() -> list[dict]:
    _chaos()
    return [_out(p) for p in products.find()]


@app.get("/products/{product_id}")
def get_product(product_id: str) -> dict:
    _chaos()
    doc = products.find_one({"_id": product_id})
    if doc is None:
        log.info("product %s not found", product_id)
        raise HTTPException(status_code=404, detail="product not found")
    return _out(doc)
