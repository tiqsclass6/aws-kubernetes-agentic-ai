from governance_common import canonical_json_bytes, is_sha256_hex, sha256_hex


def test_canonical_json_is_order_independent() -> None:
    left = {"b": 2, "a": [3, 1]}
    right = {"a": [3, 1], "b": 2}
    assert canonical_json_bytes(left) == canonical_json_bytes(right)
    assert sha256_hex(left) == sha256_hex(right)


def test_sha256_validation() -> None:
    digest = sha256_hex({"phase": 5})
    assert is_sha256_hex(digest)
    assert not is_sha256_hex("not-a-digest")
