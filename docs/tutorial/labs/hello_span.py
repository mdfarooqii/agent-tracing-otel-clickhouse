"""Module 1 lab: two spans, baggage, and the headers propagation writes.

    cd agent && .venv/bin/python ../docs/tutorial/labs/hello_span.py
"""

from opentelemetry import baggage, context, propagate, trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import ConsoleSpanExporter, SimpleSpanProcessor

provider = TracerProvider(resource=Resource.create({"service.name": "hello", "org.owner": "me"}))
provider.add_span_processor(SimpleSpanProcessor(ConsoleSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("hello")

token = context.attach(baggage.set_baggage("org.tenant", "acme_corp"))
with tracer.start_as_current_span("parent"):
    with tracer.start_as_current_span("child", attributes={"step": 1}):
        headers: dict[str, str] = {}
        propagate.inject(headers)
        print("Headers a client would send:", headers)
context.detach(token)
