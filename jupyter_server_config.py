"""Quiet RunPod's edge-proxy health-check noise on the JupyterLab port.

The RunPod proxy in front of port 8888 periodically probes ``/api/status`` with
its own token. Our Jupyter is configured for password auth (``ServerApp.token=''``),
so every probe is rejected with 403 — and Jupyter logs both a warning *and* the
full Tornado traceback for each one. None of it is actionable, so we install a
``logging.Filter`` on the ``ServerApp`` logger that drops just those two messages.

Genuine 403s on other endpoints (e.g. a real bad-password login attempt) still
get logged.
"""
import logging


class _DropProxyStatusForbidden(logging.Filter):
    """Drop the noisy /api/status 403s without hiding genuine errors."""

    def filter(self, record: logging.LogRecord) -> bool:
        msg = record.getMessage()
        # Tornado emits this line and attaches the HTTPError(403) traceback via
        # ``exc_info``. Dropping the record drops the traceback with it.
        if msg == "wrote error: 'Forbidden'":
            return False
        # Jupyter's access-log line for the same request. Matches both the
        # access logger and any future re-routing of the message.
        if "403 GET /api/status" in msg:
            return False
        return True


_filter = _DropProxyStatusForbidden()
# Both messages currently flow through the ServerApp logger (jupyter_server's
# ``self.log``); the tornado loggers are added defensively so future versions
# don't silently regress this.
for _name in ("ServerApp", "tornado.application", "tornado.access"):
    logging.getLogger(_name).addFilter(_filter)
