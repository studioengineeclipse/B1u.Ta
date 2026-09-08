"""B1-CANON-1 canonical serialization and digest.

Normative definition: SPEC/20-b1-canon-1.md. Normative implementation: core/c/libb1sig.

A strict parser is written here rather than using ``json.loads`` directly because the standard
parser silently keeps the last of a set of duplicate member names. Silent duplicate collapse is
precisely the divergence class this profile exists to eliminate: two implementations would agree a
document is valid and disagree on its digest.

Standard library only, by design — see SPEC/80 §5.
"""

from __future__ import annotations

import hashlib
import re
from typing import Any

MAX_DEPTH = 64
MAX_SAFE = 9007199254740991  # 2**53 - 1
KEY_RE = re.compile(r"^[A-Za-z0-9_$.\-]{1,64}$")

B1_ERRORS = (
    "B1_ERR_PARSE",
    "B1_ERR_NONINTEGER_NUMBER",
    "B1_ERR_KEY_SYNTAX",
    "B1_ERR_DUPLICATE_KEY",
    "B1_ERR_INVALID_UTF8",
    "B1_ERR_DEPTH",
)


class B1Error(Exception):
    def __init__(self, token: str, detail: str = "") -> None:
        super().__init__(f"{token}: {detail}" if detail else token)
        self.token = token


# ---------------------------------------------------------------------------
# Strict parser
# ---------------------------------------------------------------------------

_WS = " \t\n\r"
_DIGITS = "0123456789"


class _Parser:
    __slots__ = ("s", "i", "n")

    def __init__(self, s: str) -> None:
        self.s = s
        self.i = 0
        self.n = len(s)

    def parse(self) -> Any:
        self._ws()
        v = self._value(0)
        self._ws()
        if self.i != self.n:
            raise B1Error("B1_ERR_PARSE", f"trailing input at {self.i}")
        return v

    def _ws(self) -> None:
        while self.i < self.n and self.s[self.i] in _WS:
            self.i += 1

    def _lit(self, word: str) -> None:
        if self.s.startswith(word, self.i):
            self.i += len(word)
        else:
            raise B1Error("B1_ERR_PARSE", f"expected {word} at {self.i}")

    def _value(self, depth: int) -> Any:
        if depth > MAX_DEPTH:
            raise B1Error("B1_ERR_DEPTH", f"depth > {MAX_DEPTH}")
        if self.i >= self.n:
            raise B1Error("B1_ERR_PARSE", "unexpected end of input")
        c = self.s[self.i]
        if c == "{":
            return self._object(depth)
        if c == "[":
            return self._array(depth)
        if c == '"':
            return self._string()
        if c == "t":
            self._lit("true")
            return True
        if c == "f":
            self._lit("false")
            return False
        if c == "n":
            self._lit("null")
            return None
        if c == "-" or c in _DIGITS:
            return self._number()
        raise B1Error("B1_ERR_PARSE", f"unexpected character {c!r} at {self.i}")

    def _object(self, depth: int) -> dict:
        self.i += 1
        out: dict = {}
        self._ws()
        if self.i < self.n and self.s[self.i] == "}":
            self.i += 1
            return out
        while True:
            self._ws()
            if self.i >= self.n or self.s[self.i] != '"':
                raise B1Error("B1_ERR_PARSE", f"expected key at {self.i}")
            key = self._string()
            if not KEY_RE.match(key):
                raise B1Error("B1_ERR_KEY_SYNTAX", repr(key))
            if key in out:
                raise B1Error("B1_ERR_DUPLICATE_KEY", key)
            self._ws()
            if self.i >= self.n or self.s[self.i] != ":":
                raise B1Error("B1_ERR_PARSE", f"expected ':' at {self.i}")
            self.i += 1
            self._ws()
            out[key] = self._value(depth + 1)
            self._ws()
            if self.i >= self.n:
                raise B1Error("B1_ERR_PARSE", "unterminated object")
            c = self.s[self.i]
            if c == ",":
                self.i += 1
                continue
            if c == "}":
                self.i += 1
                return out
            raise B1Error("B1_ERR_PARSE", f"expected ',' or '}}' at {self.i}")

    def _array(self, depth: int) -> list:
        self.i += 1
        out: list = []
        self._ws()
        if self.i < self.n and self.s[self.i] == "]":
            self.i += 1
            return out
        while True:
            self._ws()
            out.append(self._value(depth + 1))
            self._ws()
            if self.i >= self.n:
                raise B1Error("B1_ERR_PARSE", "unterminated array")
            c = self.s[self.i]
            if c == ",":
                self.i += 1
                continue
            if c == "]":
                self.i += 1
                return out
            raise B1Error("B1_ERR_PARSE", f"expected ',' or ']' at {self.i}")

    def _number(self) -> int:
        start = self.i
        if self.s[self.i] == "-":
            self.i += 1
        digits_start = self.i
        while self.i < self.n and self.s[self.i] in _DIGITS:
            self.i += 1
        if self.i == digits_start:
            raise B1Error("B1_ERR_PARSE", f"expected digits at {start}")
        digits = self.s[digits_start:self.i]
        if len(digits) > 1 and digits[0] == "0":
            raise B1Error("B1_ERR_PARSE", f"leading zero at {digits_start}")
        if self.i < self.n and self.s[self.i] in ".eE":
            raise B1Error("B1_ERR_NONINTEGER_NUMBER", f"at {start}")
        text = self.s[start:self.i]
        if text == "-0":
            raise B1Error("B1_ERR_NONINTEGER_NUMBER", "negative zero")
        value = int(text)
        if value > MAX_SAFE or value < -MAX_SAFE:
            raise B1Error("B1_ERR_NONINTEGER_NUMBER", f"out of range: {text}")
        return value

    def _string(self) -> str:
        self.i += 1
        parts: list[str] = []
        while True:
            if self.i >= self.n:
                raise B1Error("B1_ERR_PARSE", "unterminated string")
            c = self.s[self.i]
            if c == '"':
                self.i += 1
                return "".join(parts)
            if c == "\\":
                self.i += 1
                if self.i >= self.n:
                    raise B1Error("B1_ERR_PARSE", "unterminated escape")
                e = self.s[self.i]
                self.i += 1
                simple = {'"': '"', "\\": "\\", "/": "/", "b": "\b",
                          "f": "\f", "n": "\n", "r": "\r", "t": "\t"}
                if e in simple:
                    parts.append(simple[e])
                elif e == "u":
                    hex4 = self.s[self.i:self.i + 4]
                    if len(hex4) != 4 or not all(h in "0123456789abcdefABCDEF" for h in hex4):
                        raise B1Error("B1_ERR_PARSE", f"bad \\u escape at {self.i}")
                    self.i += 4
                    parts.append(chr(int(hex4, 16)))
                else:
                    raise B1Error("B1_ERR_PARSE", f"bad escape \\{e}")
                continue
            if ord(c) < 0x20:
                raise B1Error("B1_ERR_PARSE", f"raw control char at {self.i}")
            parts.append(c)
            self.i += 1


def parse(text: str) -> Any:
    return _Parser(text).parse()


# ---------------------------------------------------------------------------
# Canonical serialization
# ---------------------------------------------------------------------------

_SHORT = {
    '"': '\\"', "\\": "\\\\", "\b": "\\b", "\t": "\\t",
    "\n": "\\n", "\f": "\\f", "\r": "\\r",
}


def _escape(s: str) -> str:
    out = ['"']
    for ch in s:
        short = _SHORT.get(ch)
        if short is not None:
            out.append(short)
        elif ord(ch) < 0x20:
            out.append("\\u%04x" % ord(ch))  # lowercase hex
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def _check_surrogates(s: str) -> None:
    for ch in s:
        if 0xD800 <= ord(ch) <= 0xDFFF:
            raise B1Error("B1_ERR_INVALID_UTF8", "lone surrogate")


def canonicalize(value: Any, depth: int = 0) -> str:
    if depth > MAX_DEPTH:
        raise B1Error("B1_ERR_DEPTH", f"depth > {MAX_DEPTH}")
    if value is None:
        return "null"
    # bool before int: in Python bool is a subclass of int, so the order matters here.
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, int):
        if value > MAX_SAFE or value < -MAX_SAFE:
            raise B1Error("B1_ERR_NONINTEGER_NUMBER", f"out of range: {value}")
        return str(value)
    if isinstance(value, float):
        raise B1Error("B1_ERR_NONINTEGER_NUMBER", repr(value))
    if isinstance(value, str):
        _check_surrogates(value)
        return _escape(value)
    if isinstance(value, list):
        return "[" + ",".join(canonicalize(v, depth + 1) for v in value) + "]"
    if isinstance(value, dict):
        # R2 restricts names to ASCII, so byte, code-point and UTF-16 code-unit orderings coincide
        # and Python's default string sort is unambiguous across all fourteen languages.
        keys = sorted(value.keys())
        for k in keys:
            if not isinstance(k, str) or not KEY_RE.match(k):
                raise B1Error("B1_ERR_KEY_SYNTAX", repr(k))
        return "{" + ",".join(
            _escape(k) + ":" + canonicalize(value[k], depth + 1) for k in keys
        ) + "}"
    raise B1Error("B1_ERR_PARSE", f"unsupported type {type(value).__name__}")


def digest_value(value: Any) -> str:
    return hashlib.sha256(canonicalize(value).encode("utf-8")).hexdigest()


def digest_text(text: str) -> str:
    return digest_value(parse(text))


def b1c1(digest_hex: str) -> str:
    """Algorithm-labelled identifier form. The prefix is not part of the hashed input."""
    return f"b1c1:{digest_hex}"


ZERO_LINK = "b1c1:" + "0" * 64
