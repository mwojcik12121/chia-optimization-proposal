from __future__ import annotations

import asyncio
import dataclasses
import logging
import threading

import pytest
from chia_rs import ConsensusConstants
from chia_rs.sized_bytes import bytes32
from chia_rs.sized_ints import uint8, uint16, uint64, uint128

from chia._tests.util.blockchain_mock import BlockchainMock
from chia.consensus.default_constants import DEFAULT_CONSTANTS
from chia.consensus.signage_point import SignagePoint
from chia.full_node import signage_point_validation_broker as broker_module
from chia.full_node.full_node_store import FullNodeStore, SignagePointAddResult
from chia.full_node.signage_point_validation import (
    PreparedSignagePoint,
    SignagePointCommitResult,
    SPPrepareStatus,
    SPVerifyStatus,
    verify_prepared_signage_point,
)
from chia.full_node.signage_point_validation_broker import (
    SP_VALIDATION_CAPACITY,
    SignagePointPeerBusy,
    SignagePointValidationBroker,
)
from chia.simulator.block_tools import get_signage_point
from chia.util.hash import std_hash
from chia.util.limited_semaphore import LimitedSemaphoreFullError
from chia.util.task_referencer import create_referenced_task


@pytest.fixture
def validation_state() -> tuple[ConsensusConstants, BlockchainMock, FullNodeStore, PreparedSignagePoint]:
    constants = DEFAULT_CONSTANTS.replace(DISCRIMINANT_SIZE_BITS=uint16(32), SUB_SLOT_ITERS_STARTING=uint64(4096))
    blocks = BlockchainMock({})
    store = FullNodeStore(constants)
    store.initialize_genesis_sub_slot()
    sp = get_signage_point(
        constants, blocks, None, uint128(0), uint8(2), [], constants.SUB_SLOT_ITERS_STARTING
    )
    status, prepared = store.prepare_signage_point(uint8(2), blocks, None, constants.SUB_SLOT_ITERS_STARTING, sp)
    assert status is SPPrepareStatus.READY and prepared is not None
    return constants, blocks, store, prepared


def test_preparation_is_pure_and_value_based(
    validation_state: tuple[ConsensusConstants, BlockchainMock, FullNodeStore, PreparedSignagePoint],
) -> None:
    constants, blocks, store, prepared = validation_state
    before_slots = [(slot, list(sps), iters) for slot, sps, iters in store.finished_sub_slots]
    before_recent = dict(store.recent_signage_points.cache)
    for _ in range(2):
        status, same = store.prepare_signage_point(
            uint8(2), blocks, None, constants.SUB_SLOT_ITERS_STARTING, prepared.signage_point
        )
        assert status is SPPrepareStatus.READY and same == prepared
    assert store.finished_sub_slots == before_slots
    assert dict(store.recent_signage_points.cache) == before_recent
    assert store.future_sp_cache.total_entries == 0


@pytest.mark.parametrize("component", ["normalized_cc", "segment_cc", "rc"])
def test_proof_result_taxonomy(
    validation_state: tuple[ConsensusConstants, BlockchainMock, FullNodeStore, PreparedSignagePoint],
    component: str,
) -> None:
    constants, blocks, store, _prepared = validation_state
    sp = get_signage_point(
        constants, blocks, None, uint128(0), uint8(2), [], constants.SUB_SLOT_ITERS_STARTING,
        normalized_to_identity_cc_sp=component == "normalized_cc",
    )
    assert sp.cc_proof is not None and sp.rc_proof is not None
    if component == "rc":
        proof = sp.rc_proof.replace(witness=b"\xff" * len(sp.rc_proof.witness))
        sp = SignagePoint(sp.cc_vdf, sp.cc_proof, sp.rc_vdf, proof)
    else:
        proof = sp.cc_proof.replace(witness=b"\xff" * len(sp.cc_proof.witness))
        sp = SignagePoint(sp.cc_vdf, proof, sp.rc_vdf, sp.rc_proof)
    status, prepared = store.prepare_signage_point(uint8(2), blocks, None, constants.SUB_SLOT_ITERS_STARTING, sp)
    assert status is SPPrepareStatus.READY and prepared is not None
    verified = verify_prepared_signage_point(constants, prepared)
    expected = SPVerifyStatus.CACHE_FOR_FUTURE if component == "segment_cc" else SPVerifyStatus.INVALID_VDF
    assert verified is expected
    result = store.commit_prepared_signage_point(prepared, verified, blocks, None, constants.SUB_SLOT_ITERS_STARTING)
    if component == "segment_cc":
        assert result is SignagePointCommitResult.CACHE_FOR_FUTURE
        assert store.in_future_sp_cache(sp, uint8(2))
    else:
        assert result is SignagePointCommitResult.INVALID_VDF
        assert store.future_sp_cache.total_entries == 0
    assert all(sp is None for _slot, sps, _iters in store.finished_sub_slots for sp in sps)


def test_changed_context_cannot_commit_or_penalize(
    validation_state: tuple[ConsensusConstants, BlockchainMock, FullNodeStore, PreparedSignagePoint],
) -> None:
    constants, blocks, store, prepared = validation_state
    stale = dataclasses.replace(
        prepared, context=dataclasses.replace(prepared.context, prior_block_hash=std_hash(b"different prior block"))
    )
    for verified in (SPVerifyStatus.VALID, SPVerifyStatus.INVALID_VDF, SPVerifyStatus.CACHE_FOR_FUTURE):
        assert store.commit_prepared_signage_point(
            stale, verified, blocks, None, constants.SUB_SLOT_ITERS_STARTING
        ) is SignagePointCommitResult.CONTEXT_CHANGED
    assert store.future_sp_cache.total_entries == 0
    assert len(store.recent_signage_points.cache) == 0


def test_duplicate_commit_and_compatibility_wrapper(
    validation_state: tuple[ConsensusConstants, BlockchainMock, FullNodeStore, PreparedSignagePoint],
) -> None:
    constants, blocks, store, prepared = validation_state
    verified = verify_prepared_signage_point(constants, prepared)
    assert verified is SPVerifyStatus.VALID
    assert store.commit_prepared_signage_point(
        prepared, verified, blocks, None, constants.SUB_SLOT_ITERS_STARTING
    ) is SignagePointCommitResult.ADDED
    assert store.commit_prepared_signage_point(
        prepared, verified, blocks, None, constants.SUB_SLOT_ITERS_STARTING
    ) is SignagePointCommitResult.DUPLICATE_OR_OLDER
    assert len(store.recent_signage_points.cache) == 1
    for skip in (False, True):
        other = FullNodeStore(constants)
        other.initialize_genesis_sub_slot()
        assert other.new_signage_point(
            uint8(2), blocks, None, constants.SUB_SLOT_ITERS_STARTING, prepared.signage_point,
            skip_vdf_validation=skip,
        ) is SignagePointAddResult.ADDED
        assert other.finished_sub_slots == store.finished_sub_slots


@pytest.mark.anyio
async def test_broker_coalesces_and_retains_cancelled_work(
    validation_state: tuple[ConsensusConstants, BlockchainMock, FullNodeStore, PreparedSignagePoint],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    constants, _blocks, _store, prepared = validation_state
    started = asyncio.Event()
    joined = asyncio.Event()
    release = threading.Event()
    loop = asyncio.get_running_loop()

    def slow_verify(constants: ConsensusConstants, prepared: PreparedSignagePoint) -> SPVerifyStatus:
        loop.call_soon_threadsafe(started.set)
        if not release.wait(10):
            raise TimeoutError("test did not release VDF worker")
        return verify_prepared_signage_point(constants, prepared)

    monkeypatch.setattr(broker_module, "verify_prepared_signage_point", slow_verify)
    async with SignagePointValidationBroker.managed(constants, logging.getLogger(__name__)) as broker:
        digest = std_hash(bytes(prepared.signage_point))
        first = create_referenced_task(broker.verify(digest, prepared, std_hash(b"first peer")))
        try:
            await asyncio.wait_for(started.wait(), 5)
            first.cancel()
            with pytest.raises(asyncio.CancelledError):
                await first
            assert broker.active == 1 and len(broker._inflight) == 1

            async def join() -> SPVerifyStatus:
                joined.set()
                return await broker.verify(digest, prepared, std_hash(b"second peer"))

            second = create_referenced_task(join())
            await joined.wait()
            assert broker.results["coalesced"] == 1
            changed = dataclasses.replace(
                prepared, context=dataclasses.replace(prepared.context, next_sub_slot_iters=uint64(8192))
            )
            with pytest.raises(SignagePointPeerBusy):
                await broker.verify(digest, changed, std_hash(b"third peer"))
            release.set()
            assert await second is SPVerifyStatus.VALID
            assert broker.active == 0 and not broker._inflight and not broker._peer_jobs
        finally:
            release.set()


@pytest.mark.anyio
async def test_broker_bounds_waiting_jobs(
    validation_state: tuple[ConsensusConstants, BlockchainMock, FullNodeStore, PreparedSignagePoint],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    constants, _blocks, _store, prepared = validation_state
    started = asyncio.Event()
    queued = asyncio.Event()
    release = threading.Event()
    loop = asyncio.get_running_loop()

    def slow_verify(constants: ConsensusConstants, prepared: PreparedSignagePoint) -> SPVerifyStatus:
        loop.call_soon_threadsafe(started.set)
        if not release.wait(10):
            raise TimeoutError("test did not release VDF worker")
        return verify_prepared_signage_point(constants, prepared)

    monkeypatch.setattr(broker_module, "verify_prepared_signage_point", slow_verify)
    async with SignagePointValidationBroker.managed(constants, logging.getLogger(__name__)) as broker:
        tasks = []
        enqueued = 0

        async def submit(index: int) -> SPVerifyStatus:
            nonlocal enqueued
            enqueued += 1
            if enqueued == SP_VALIDATION_CAPACITY:
                queued.set()
            # Distinct digests exercise the budget; verification still consumes real immutable VDF inputs.
            key: bytes32 = std_hash(index.to_bytes(4, "big"))
            return await broker.verify(key, prepared, key)

        try:
            tasks.append(create_referenced_task(submit(0)))
            await asyncio.wait_for(started.wait(), 5)
            tasks.extend(create_referenced_task(submit(i)) for i in range(1, SP_VALIDATION_CAPACITY))
            await queued.wait()
            assert broker.active == 1 and broker.waiting == SP_VALIDATION_CAPACITY - 1
            with pytest.raises(LimitedSemaphoreFullError):
                await broker.verify(std_hash(b"excess"), prepared, std_hash(b"excess peer"))
            tasks[0].cancel()
            with pytest.raises(asyncio.CancelledError):
                await tasks[0]
            assert broker.active == 1 and broker.waiting == SP_VALIDATION_CAPACITY - 1
        finally:
            release.set()
            await asyncio.gather(*tasks, return_exceptions=True)
    assert broker.active == 0 and not broker._inflight and not broker._peer_jobs