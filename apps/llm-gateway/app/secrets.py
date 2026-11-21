"""Secrets read from FILES, re-read when they change.

Why a file and not an environment variable: an env var is visible in
/proc/<pid>/environ, inherited by every child process, copied into crash
dumps and debug output, and frozen for the life of the process. A file
mounted by the Secrets Store CSI driver (from Azure Key Vault) lives on a
tmpfs, is readable by the app user only, and is replaced in place when the
secret rotates — this class picks the new value up without a restart.
"""

import logging
import os
import threading

logger = logging.getLogger("llm_gateway.secrets")


class FileSecret:
    """A secret stored in a file. Cached; re-read only when the file changes.

    The CSI driver swaps mounted files atomically (symlink switch), so a
    rotation shows up as a new (mtime, size, inode) of the resolved path.
    """

    def __init__(self, path: str):
        self.path = path
        self._lock = threading.Lock()
        self._stamp: tuple[int, int, int] | None = None
        self._value = ""

    def __repr__(self) -> str:  # never the value
        return f"FileSecret(path={self.path!r})"

    def get(self) -> str:
        try:
            st = os.stat(self.path)  # follows the CSI symlink
        except OSError:
            # Missing = not provisioned (yet). Logs the PATH only, never the
            # content (the Semgrep rule matches the word "secret").
            logger.warning("secret file not readable: %s", self.path)  # nosemgrep: python.lang.security.audit.logging.logger-credential-leak.python-logger-credential-disclosure
            return ""
        stamp = (st.st_mtime_ns, st.st_size, st.st_ino)
        with self._lock:
            if stamp != self._stamp:
                with open(self.path, encoding="utf-8") as f:
                    self._value = f.read().strip()
                if self._stamp is not None:
                    # Path only — the value is never logged.
                    logger.info("secret rotated: %s", self.path)  # nosemgrep: python.lang.security.audit.logging.logger-credential-leak.python-logger-credential-disclosure
                self._stamp = stamp
            return self._value
