from fastapi import FastAPI, Request, HTTPException, Depends
from hashlib import sha256
from datetime import datetime, timedelta
import time
from .config import (
    enable_secret,
    API_KEYS_STATIC,
    DOWNLOAD_BASE_SECRET,
    ROTATE_INTERVAL_MINUTES,
)

# --- Helper functions ---
def current_key_window() -> int:
    """
    Returns the current 30-minute window number since epoch.
    """
    return int(time.time() // (ROTATE_INTERVAL_MINUTES * 60))

def generate_download_key() -> str:
    """
    Generate hashed key for current window.
    """
    window = current_key_window()
    raw = f"{DOWNLOAD_BASE_SECRET}-{window}"
    return sha256(raw.encode()).hexdigest()

def verify_download_key(received_key: str) -> bool:
    """
    Accept current or previous window key (to allow slight delay).
    """
    window = current_key_window()
    # Check current window
    if sha256(f"{DOWNLOAD_BASE_SECRET}-{window}".encode()).hexdigest() == received_key:
        return True
    # Check previous window (grace period)
    if sha256(f"{DOWNLOAD_BASE_SECRET}-{window-1}".encode()).hexdigest() == received_key:
        return True
    return False

# --- Dependency factory ---
def verify_api_key(endpoint_name: str):
    async def dependency(request: Request):
        if enable_secret:
            api_key_received = request.headers.get("X-API-Key")
            if not api_key_received:
                raise HTTPException(status_code=401, detail="Unauthorized: Missing API key")

            if endpoint_name in API_KEYS_STATIC:
                # Static key check
                if api_key_received != API_KEYS_STATIC[endpoint_name]:
                    raise HTTPException(status_code=401, detail="Unauthorized: Invalid API key")
            elif endpoint_name == "download":
                # Rotating key check
                if not verify_download_key(api_key_received):
                    raise HTTPException(status_code=401, detail="Unauthorized: Invalid download key")
            else:
                raise HTTPException(status_code=401, detail="Unauthorized: Unknown endpoint")
    return dependency

