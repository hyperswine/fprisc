"""Ed25519 challenge-response. This server never imports a login private key."""
import base64
import hashlib
import json
from pathlib import Path
import re
import secrets
import threading
import time
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

COOKIE = "print_room_session"
BINDING = "print_room_challenge"
CHALLENGE_SECONDS = 60
SESSION_SECONDS = 8 * 60 * 60


def load_keys(path):
    rows = json.loads(Path(path).read_text())
    if not isinstance(rows, list) or not 1 <= len(rows) <= 32:
        raise ValueError("auth must contain 1..32 public keys")
    seen = set()
    for row in rows:
        if (not isinstance(row, dict) or set(row) != {"name", "algorithm", "public_key"}
                or row["algorithm"] != "Ed25519" or not isinstance(row["name"], str)
                or not 1 <= len(row["name"]) <= 80 or not isinstance(row["public_key"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", row["public_key"]) or row["public_key"] in seen):
            raise ValueError("auth requires unique Ed25519 public keys and names")
        Ed25519PublicKey.from_public_bytes(bytes.fromhex(row["public_key"]))
        seen.add(row["public_key"])
    return rows


class Auth:
    def __init__(self, keys):
        self.keys = keys
        self.pending = {}
        self.sessions = {}
        self.attempts = {}
        self.lock = threading.RLock()

    def prune(self):
        now = time.monotonic()
        for table in (self.pending, self.sessions):
            for key, row in list(table.items()):
                if row[0] <= now:
                    del table[key]
        for key, row in list(self.attempts.items()):
            if row[0] <= now:
                del self.attempts[key]

    def challenge(self, origin, address):
        with self.lock:
            self.prune()
            until, count = self.attempts.get(address, (time.monotonic() + 60, 0))
            if count >= 20 or len(self.pending) >= 1024 or len(self.attempts) >= 4096:
                raise ValueError("Too many attempts. Try again in a minute.")
            self.attempts[address] = (until, count + 1)
            challenge_id, binding = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
            message = "Print room login v1\n" + origin + "\n" + challenge_id
            self.pending[challenge_id] = (time.monotonic() + CHALLENGE_SECONDS, origin, binding, message.encode())
            return {"id": challenge_id, "message": message, "expires_in": CHALLENGE_SECONDS}, binding

    def verify(self, value, origin, binding):
        if not isinstance(value, dict) or set(value) != {"id", "signature"}:
            raise ValueError("Invalid login response.")
        if not isinstance(value["id"], str) or not isinstance(value["signature"], str) or len(value["signature"]) != 88:
            raise ValueError("Invalid login response.")
        with self.lock:
            self.prune()
            row = self.pending.pop(value["id"], None)  # consume even a failed signature
            if not row or row[1] != origin or not secrets.compare_digest(row[2], binding):
                raise ValueError("Challenge expired or already used. Sign in again.")
            try:
                signature = base64.b64decode(value["signature"], validate=True)
                if len(signature) != 64:
                    raise ValueError()
            except ValueError:
                raise ValueError("Invalid signature.") from None
            for key in self.keys:
                try:
                    Ed25519PublicKey.from_public_bytes(bytes.fromhex(key["public_key"])).verify(signature, row[3])
                except InvalidSignature:
                    continue
                if len(self.sessions) >= 1024:
                    raise ValueError("Session capacity reached. Try later.")
                token = secrets.token_urlsafe(32)
                self.sessions[hashlib.sha256(token.encode()).digest()] = (time.monotonic() + SESSION_SECONDS, origin, key["public_key"])
                return token
            raise ValueError("This key is not authorized.")

    def valid(self, token, origin):
        if not isinstance(token, str) or len(token) > 128:
            return False
        with self.lock:
            row = self.sessions.get(hashlib.sha256(token.encode()).digest())
            return bool(row and row[0] > time.monotonic() and row[1] == origin)

    def logout(self, token):
        with self.lock:
            self.sessions.pop(hashlib.sha256(token.encode()).digest(), None)
