from __future__ import annotations

from types import SimpleNamespace
from typing import Any, cast

import pytest
from chia_rs.sized_bytes import bytes32

from chia.consensus.blockchain import Blockchain
from chia.consensus.fork_order import calculate_fork_tie_key, exact_tie_order


def test_fork_tie_key_fixed_vector() -> None:
    block_record = SimpleNamespace(
        height=10,
        weight=20,
        total_iters=30,
        prev_hash=bytes32(b"\x44" * 32),
    )
    proof_of_space = SimpleNamespace(
        challenge=bytes32(b"\x11" * 32),
        proof=b"proof",
        compute_plot_id=lambda: bytes32(b"\x22" * 32),
    )

    key = calculate_fork_tie_key(
        cast(Any, block_record),
        cast(Any, proof_of_space),
        bytes32(b"\x33" * 32),
    )

    assert key.hex() == "9645b911174741322cf95b93ff6d73272da146d6f79083fb7e9e8e7501a206a3"


def test_tie_order_is_transitive_and_uses_header_hash_as_fallback() -> None:
    zero = bytes32.zeros
    a = exact_tie_order(bytes32(b"\x01" * 32), zero)
    b = exact_tie_order(bytes32(b"\x02" * 32), zero)
    c = exact_tie_order(bytes32(b"\x03" * 32), zero)
    assert a < b < c
    assert a < c

    tie_key = bytes32(b"\x04" * 32)
    assert exact_tie_order(tie_key, bytes32(b"\x05" * 32)) < exact_tie_order(
        tie_key, bytes32(b"\x06" * 32)
    )


class _KeyStore:
    def __init__(self, key: bytes32 | None) -> None:
        self.key = key

    async def get_fork_order_key(self, header_hash: bytes32) -> bytes32 | None:
        return self.key


def _record(header_byte: int) -> SimpleNamespace:
    return SimpleNamespace(
        height=100,
        weight=200,
        total_iters=300,
        header_hash=bytes32(bytes([header_byte]) * 32),
    )


@pytest.mark.anyio
async def test_exact_tie_preserves_legacy_arrival_order_before_activation() -> None:
    candidate = _record(1)
    peak = _record(2)
    blockchain = SimpleNamespace(
        constants=SimpleNamespace(FORK_TIE_BREAK_HEIGHT=101),
        block_store=_KeyStore(bytes32(b"\xff" * 32)),
    )

    assert not await Blockchain._candidate_beats_peak(
        cast(Any, blockchain),
        cast(Any, candidate),
        bytes32.zeros,
        cast(Any, peak),
    )


@pytest.mark.anyio
async def test_weight_and_iterations_keep_precedence_over_tie_key() -> None:
    peak = _record(2)
    blockchain = SimpleNamespace(
        constants=SimpleNamespace(FORK_TIE_BREAK_HEIGHT=0),
        block_store=_KeyStore(bytes32(b"\xff" * 32)),
    )
    lower_weight = SimpleNamespace(**{**vars(_record(1)), "weight": 199})
    more_iterations = SimpleNamespace(**{**vars(_record(1)), "total_iters": 301})

    assert not await Blockchain._candidate_beats_peak(
        cast(Any, blockchain), cast(Any, lower_weight), bytes32.zeros, cast(Any, peak)
    )
    assert not await Blockchain._candidate_beats_peak(
        cast(Any, blockchain), cast(Any, more_iterations), bytes32.zeros, cast(Any, peak)
    )


@pytest.mark.anyio
async def test_exact_tie_converges_after_activation() -> None:
    record_1 = _record(1)
    record_2 = _record(2)
    candidate_key = bytes32(b"\x10" * 32)
    peak_key = bytes32(b"\x20" * 32)
    node_with_record_2_first = SimpleNamespace(
        constants=SimpleNamespace(FORK_TIE_BREAK_HEIGHT=100),
        block_store=_KeyStore(peak_key),
    )

    assert await Blockchain._candidate_beats_peak(
        cast(Any, node_with_record_2_first),
        cast(Any, record_1),
        candidate_key,
        cast(Any, record_2),
    )

    node_with_record_1_first = SimpleNamespace(
        constants=SimpleNamespace(FORK_TIE_BREAK_HEIGHT=100),
        block_store=_KeyStore(candidate_key),
    )
    assert not await Blockchain._candidate_beats_peak(
        cast(Any, node_with_record_1_first),
        cast(Any, record_2),
        peak_key,
        cast(Any, record_1),
    )


@pytest.mark.anyio
async def test_missing_post_activation_peak_key_fails_loudly() -> None:
    blockchain = SimpleNamespace(
        constants=SimpleNamespace(FORK_TIE_BREAK_HEIGHT=100),
        block_store=_KeyStore(None),
    )

    with pytest.raises(RuntimeError, match="missing fork-order key"):
        await Blockchain._candidate_beats_peak(
            cast(Any, blockchain),
            cast(Any, _record(1)),
            bytes32.zeros,
            cast(Any, _record(2)),
        )
