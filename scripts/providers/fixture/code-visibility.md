<!-- Consumed by the Phase-2 semantic-code-visibility verification layer (round-1 sentinel + round-2 judge); not dead/unwired content. -->
# Fixture for semantic code-visibility verification

Sentinel: ZETA-9-ORANGE-7f3a

## Sample code (excerpt)

```python
class UnknownModel(Exception):
    """Raised when a model id is absent from a provider's catalog."""


def resolve_alias(provider_id, model_id):
    """Resolve a provider+model pair into a launchable alias."""
    catalog = fetch_catalog(provider_id)
    if model_id not in catalog:
        raise UnknownModel(model_id)
    return Alias(provider=provider_id, model=model_id, strong=is_strong(model_id))


class TokenBucket:
    """A simple token-bucket rate limiter for provider probes."""

    def __init__(self, rate, capacity):
        self.rate = rate
        self.capacity = capacity
        self.tokens = capacity

    def consume(self, amount=1):
        if amount > self.tokens:
            return False
        self.tokens -= amount
        return True
```
