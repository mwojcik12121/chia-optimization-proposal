from __future__ import annotations

from chia_rs import BlockRecord, ProofOfSpace
from chia_rs.sized_bytes import bytes32

from chia.util.hash import std_hash

PROOF_COMMITMENT_DOMAIN = b"chia-fork-proof-v1"
FORK_ORDER_DOMAIN = b"chia-fork-order-v1"
FORK_ORDER_KEY_VERSION = 1


def calculate_fork_tie_key(
    block_record: BlockRecord,
    proof_of_space: ProofOfSpace,
    validated_quality: bytes32,
) -> bytes32:
    """Return the canonical, candidate-local ordering key for an exact tie."""

    proof_commitment = std_hash(
        PROOF_COMMITMENT_DOMAIN
        + bytes(proof_of_space.challenge)
        + bytes(proof_of_space.compute_plot_id())
        + bytes(std_hash(proof_of_space.proof))
        + bytes(validated_quality)
    )

    return std_hash(
        FORK_ORDER_DOMAIN
        + int(block_record.height).to_bytes(4, "big", signed=False)
        + int(block_record.weight).to_bytes(16, "big", signed=False)
        + int(block_record.total_iters).to_bytes(16, "big", signed=False)
        + bytes(block_record.prev_hash)
        + bytes(proof_commitment)
    )


def exact_tie_order(tie_key: bytes32, header_hash: bytes32) -> tuple[bytes, bytes]:
    """Smaller proof key wins; the header hash is the collision fallback."""

    return bytes(tie_key), bytes(header_hash)
