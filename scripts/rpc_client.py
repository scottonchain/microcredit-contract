"""Small, shared JSON-RPC transport for read-only chain verification scripts.

It validates the response envelope and preserves revert data for negative controls.
Transport/protocol failures remain failures; they must never count as an EVM revert.
"""
import json
import urllib.error
import urllib.request

USER_AGENT = "microcredit-verifier/1 (+https://github.com/scottonchain/microcredit-contract)"


class RpcError(RuntimeError):
    def __init__(self, message, data=None, code=None):
        super().__init__(message)
        self.data = data
        self.code = code


def rpc(url, method, params, *, timeout=30):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    request = urllib.request.Request(
        url, data=body, headers={"content-type": "application/json", "user-agent": USER_AGENT}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise RpcError(f"{method}: HTTP {error.code}") from error
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        # URLs can carry provider credentials; do not echo the endpoint in diagnostics.
        raise RpcError(f"{method}: the RPC endpoint could not be reached") from error
    except (ValueError, UnicodeError) as error:
        raise RpcError(f"{method}: the RPC endpoint did not return JSON") from error
    if not isinstance(result, dict) or result.get("jsonrpc") != "2.0" or result.get("id") != 1:
        raise RpcError(f"{method}: invalid JSON-RPC response envelope")
    if ("error" in result) == ("result" in result):
        raise RpcError(f"{method}: expected exactly one of result and error")
    if "error" in result:
        error = result["error"]
        if not isinstance(error, dict):
            raise RpcError(f"{method}: invalid JSON-RPC error")
        raise RpcError(f"{method}: {error.get('message', 'RPC error')}", error.get("data"), error.get("code"))
    return result["result"]
