from __future__ import annotations

import dataclasses
import enum

from chia_rs import ConsensusConstants
from chia_rs.sized_bytes import bytes32
from chia_rs.sized_ints import uint8, uint64, uint128

from chia.consensus.signage_point import SignagePoint
from chia.types.blockchain_format.classgroup import ClassgroupElement
from chia.types.blockchain_format.vdf import VDFInfo, validate_vdf


class SPPrepareStatus(enum.Enum):
    READY = "ready"
    REJECTED = "rejected"
    CACHE_FOR_FUTURE = "cache_for_future"


class SPVerifyStatus(enum.Enum):
    VALID = "valid"
    CACHE_FOR_FUTURE = "cache_for_future"
    INVALID_VDF = "invalid_vdf"


class SignagePointCommitResult(enum.Enum):
    ADDED = "added"
    DUPLICATE_OR_OLDER = "duplicate_or_older"
    CONTEXT_CHANGED = "context_changed"
    CACHE_FOR_FUTURE = "cache_for_future"
    INVALID_VDF = "invalid_vdf"


@dataclasses.dataclass(frozen=True)
class SignagePointValidationContext:
    peak_header_hash: bytes32 | None
    index: uint8
    slot_cc_hash: bytes32
    slot_rc_hash: bytes32
    slot_start_total_iters: uint128
    next_sub_slot_iters: uint64
    prior_block_hash: bytes32 | None
    cc_start_element: ClassgroupElement
    expected_cc: VDFInfo
    expected_rc: VDFInfo


@dataclasses.dataclass(frozen=True)
class PreparedSignagePoint:
    context: SignagePointValidationContext
    signage_point: SignagePoint


def verify_prepared_signage_point(
    constants: ConsensusConstants, prepared: PreparedSignagePoint
) -> SPVerifyStatus:
    """Pure native verification: no blockchain/store references or mutations."""
    sp = prepared.signage_point
    ctx = prepared.context
    assert sp.cc_vdf is not None and sp.cc_proof is not None
    assert sp.rc_vdf is not None and sp.rc_proof is not None
    identity = ClassgroupElement.get_default_element()
    if sp.cc_proof.normalized_to_identity:
        if not validate_vdf(sp.cc_proof, constants, identity, sp.cc_vdf):
            return SPVerifyStatus.INVALID_VDF
    elif not validate_vdf(sp.cc_proof, constants, ctx.cc_start_element, ctx.expected_cc):
        # An honest same-slot fork can use a different prior in-slot block.
        return SPVerifyStatus.CACHE_FOR_FUTURE

    # Preserve the legacy ordering: CC proof classification precedes RC info matching.
    if ctx.expected_rc != sp.rc_vdf:
        return SPVerifyStatus.CACHE_FOR_FUTURE
    if not validate_vdf(sp.rc_proof, constants, identity, sp.rc_vdf, ctx.expected_rc):
        return SPVerifyStatus.INVALID_VDF
    return SPVerifyStatus.VALID