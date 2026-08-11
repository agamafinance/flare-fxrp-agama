// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title JsonLite
 * @notice Minimal depth-aware JSON reader for verifying attestation claims at their EXACT path.
 *
 *   A raw substring scan over a JWT is unsafe: operator-controlled map keys (Confidential Space
 *   `submods.container.env` variable names, image labels) inject real `"key":"value"` pairs anywhere
 *   in the token, so a debug / non-TDX / wrong-image workload can forge every claim. This reader finds
 *   a key only at the TOP LEVEL of a given object range, so nested or injected duplicates are ignored.
 *
 *   The RSA signature is verified before parsing, so the payload is always well-formed Google JSON;
 *   this reader does not need to defend against malformed input (an attacker cannot forge the sig).
 */
library JsonLite {
    /// Find `key` at the top level of the object j[start..end) (j[start] must be '{'). Returns the
    /// value content bounds [vs, ve): a string excludes its quotes; an object/array includes its
    /// delimiters; a primitive spans its token. Reverts if the key is absent at this level.
    function get(bytes memory j, uint256 start, uint256 end, bytes memory key)
        internal
        pure
        returns (uint256 vs, uint256 ve)
    {
        require(j[start] == "{", "not object");
        uint256 i = start + 1;
        while (i < end) {
            bytes1 c = j[i];
            if (c == "}") revert("key not found");
            if (c == " " || c == "," || c == "\n" || c == "\t" || c == "\r") {
                i++;
                continue;
            }
            require(c == '"', "expect key");
            (uint256 ks, uint256 ke) = _str(j, i);
            uint256 p = ke + 1;
            while (j[p] != ":") p++;
            p++;
            while (j[p] == " ") p++;
            (uint256 cs, uint256 ce, uint256 next) = _value(j, p);
            if (_eq(j, ks, ke, key)) return (cs, ce);
            i = next;
        }
        revert("key not found");
    }

    /// content bounds of the string at j[i] ('"'), excluding the quotes.
    function _str(bytes memory j, uint256 i) private pure returns (uint256 s, uint256 e) {
        s = i + 1;
        e = s;
        while (j[e] != '"') {
            if (j[e] == "\\") e++;
            e++;
        }
    }

    /// content bounds [cs, ce) of the value at p, plus `next` = index just past the value token.
    function _value(bytes memory j, uint256 p) private pure returns (uint256 cs, uint256 ce, uint256 next) {
        bytes1 c = j[p];
        if (c == '"') {
            (uint256 a, uint256 b) = _str(j, p);
            return (a, b, b + 1);
        }
        if (c == "{" || c == "[") {
            uint256 depth = 0;
            uint256 i = p;
            bool inStr = false;
            while (true) {
                bytes1 x = j[i];
                if (inStr) {
                    if (x == "\\") {
                        i += 2;
                        continue;
                    }
                    if (x == '"') inStr = false;
                    i++;
                    continue;
                }
                if (x == '"') inStr = true;
                else if (x == "{" || x == "[") depth++;
                else if (x == "}" || x == "]") {
                    depth--;
                    if (depth == 0) return (p, i + 1, i + 1);
                }
                i++;
            }
        }
        uint256 k = p;
        while (j[k] != "," && j[k] != "}" && j[k] != "]") k++;
        return (p, k, k);
    }

    function _eq(bytes memory j, uint256 s, uint256 e, bytes memory k) private pure returns (bool) {
        if (e - s != k.length) return false;
        for (uint256 i = 0; i < k.length; i++) {
            if (j[s + i] != k[i]) return false;
        }
        return true;
    }

    /// true if the value range j[s..e) equals `expected`.
    function equals(bytes memory j, uint256 s, uint256 e, bytes memory expected) internal pure returns (bool) {
        return _eq(j, s, e, expected);
    }

    /// parse a decimal number token j[s..e) into a uint (stops at the first non-digit).
    function toUint(bytes memory j, uint256 s, uint256 e) internal pure returns (uint256 n) {
        for (uint256 i = s; i < e; i++) {
            uint8 d = uint8(j[i]);
            if (d < 48 || d > 57) break;
            n = n * 10 + (d - 48);
        }
    }
}
