import os
import sys

import pytest

# Make `base` and `app` importable the same way main.py does.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import handlers  # noqa: E402
from tests.helpers import stub_chain  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_extension(monkeypatch):
    """Every test starts from an empty book and a healthy stubbed chain."""
    handlers.reset_state()
    stub_chain(monkeypatch)
    yield
    handlers.reset_state()
