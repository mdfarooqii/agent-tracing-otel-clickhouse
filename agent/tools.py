"""Agent tools. Most call the temporary APIs in apis.py over HTTP."""

from __future__ import annotations

import random
import time
from urllib.parse import quote, urlencode

from langchain_core.tools import tool

from telemetry import ApiError, call_api

KB_SEARCH_API = "http://127.0.0.1:18081"
TICKET_API = "http://127.0.0.1:18082"
PRICING_API = "http://127.0.0.1:18083"
LEGACY_HR_API = "http://127.0.0.1:18084"


@tool
def search_knowledge_base(query: str, simulate_failure: bool = False) -> str:
    """Look up internal notes that match the query."""
    params = {"q": query, **({"fail": "1"} if simulate_failure else {})}
    result = call_api("GET", f"{KB_SEARCH_API}/v1/search?{urlencode(params)}", "/v1/search")
    return " ".join(result["hits"]) or "No matching notes."


@tool
def count_words(text: str) -> int:
    """Count the words in a draft answer."""
    time.sleep(random.uniform(0.05, 0.15))
    return len(text.split())


@tool
def lookup_employee(employee_id: str) -> dict:
    """Fetch an employee record from the HR system."""
    return call_api("GET", f"{LEGACY_HR_API}/employees/{quote(employee_id)}", "/employees/{employee_id}")


@tool
def create_ticket(summary: str, queue: str) -> str:
    """Open a ticket in a support queue and return its id."""
    return call_api("POST", f"{TICKET_API}/v1/tickets", "/v1/tickets", {"summary": summary, "queue": queue})["id"]


@tool
def get_price(sku: str) -> float:
    """Get the list price of a SKU. Retries once, since the pricing API is flaky."""
    url = f"{PRICING_API}/v1/prices/{quote(sku)}"
    try:
        return call_api("GET", url, "/v1/prices/{sku}")["price"]
    except ApiError:
        return call_api("GET", url, "/v1/prices/{sku}")["price"]
