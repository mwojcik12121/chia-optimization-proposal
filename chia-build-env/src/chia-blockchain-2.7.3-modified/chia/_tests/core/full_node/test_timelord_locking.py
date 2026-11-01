from __future__ import annotations

import asyncio
import dataclasses
import logging
from pathlib import Path
from typing import Any

import pytest
from chia_rs.sized_bytes import bytes32
from chia_rs.sized_ints import uint8, uint32

from chia.consensus.default_constants import DEFAULT_CONSTANTS
from chia.full_node.full_node import FullNode, SignagePointPublishPlan, TimelordPostCommitPlan
from chia.full_node.full_node_store import FullNodeStore
from chia.protocols import farmer_protocol
from chia.protocols.outbound_message import Message, NodeType, make_msg
from chia.protocols.protocol_message_types import ProtocolMessageTypes
from chia.util.hash import std_hash
from chia.util.task_referencer import create_referenced_task


class BlockingServer:
    """Network boundary with deterministic backpressure; actual node publication code is exercised."""

    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.release = asyncio.Event()
        self.messages: list[tuple[Message, NodeType]] = []

    async def send_to_all(
        self, messages: list[Message], node_type: NodeType, exclude: bytes32 | None = None
    ) -> None:
        self.messages.extend((message, node_type) for message in messages)
        if node_type is NodeType.FULL_NODE:
            self.started.set()
            await self.release.wait()


def make_node(tmp_path: Path, server: BlockingServer) -> FullNode:
    store = FullNodeStore(DEFAULT_CONSTANTS)
    store.initialize_genesis_sub_slot()
    node = FullNode(
        root_path=tmp_path,
        config={},
        constants=DEFAULT_CONSTANTS,
        signage_point_times=[0.0] * DEFAULT_CONSTANTS.NUM_SPS_SUB_SLOT,
        full_node_store=store,
        log=logging.getLogger(__name__),
        db_path=tmp_path / "unused.sqlite",
        wallet_sync_queue=asyncio.Queue(),
    )
    node._timelord_lock = asyncio.Lock()
    node._server = server  # type: ignore[assignment]
    return node


def make_farmer_payload() -> farmer_protocol.NewSignagePoint:
    return farmer_protocol.NewSignagePoint(
        DEFAULT_CONSTANTS.GENESIS_CHALLENGE,
        DEFAULT_CONSTANTS.GENESIS_CHALLENGE,
        DEFAULT_CONSTANTS.GENESIS_CHALLENGE,
        DEFAULT_CONSTANTS.DIFFICULTY_STARTING,
        DEFAULT_CONSTANTS.SUB_SLOT_ITERS_STARTING,
        uint8(2),
        uint32(0),
        uint32(0),
    )


@pytest.mark.anyio
async def test_blocked_publication_releases_state_lock(tmp_path: Path) -> None:
    server = BlockingServer()
    node = make_node(tmp_path, server)
    payload = make_farmer_payload()
    farmer_message = make_msg(ProtocolMessageTypes.new_signage_point, payload)
    plan = SignagePointPublishPlan(farmer_message, farmer_message, payload, std_hash(b"peer"))
    publisher = create_referenced_task(node.publish_signage_point(plan))
    try:
        await asyncio.wait_for(server.started.wait(), 5)
        async with node.timelord_state_lock("farmer_declare_test"):
            assert not publisher.done()
        server.release.set()
        await publisher
        assert [target for _message, target in server.messages] == [NodeType.FULL_NODE, NodeType.FARMER]
    finally:
        server.release.set()
        await asyncio.gather(publisher, return_exceptions=True)


@pytest.mark.anyio
async def test_eos_dispatch_preserves_commit_order_after_cancellation(tmp_path: Path) -> None:
    server = BlockingServer()
    node = make_node(tmp_path, server)
    message1 = make_msg(ProtocolMessageTypes.new_signage_point, make_farmer_payload())
    message2 = make_msg(
        ProtocolMessageTypes.new_signage_point, dataclasses.replace(make_farmer_payload(), signage_point_index=uint8(3))
    )
    async with node._manage_timelord_dispatcher():
        async with node.timelord_state_lock("eos_test_first"):
            completion1 = node._enqueue_timelord_plan(
                TimelordPostCommitPlan(1, message1, message1, None, ())
            )
        try:
            await asyncio.wait_for(server.started.wait(), 5)
            async with node.timelord_state_lock("eos_test_second"):
                completion2 = node._enqueue_timelord_plan(
                    TimelordPostCommitPlan(2, message2, message2, None, ())
                )
            caller = asyncio.shield(completion1)
            caller.cancel()
            with pytest.raises(asyncio.CancelledError):
                await caller
            assert not completion1.cancelled() and not completion2.done()
            stop1 = create_referenced_task(node._stop_timelord_dispatcher())
            stop2 = create_referenced_task(node._stop_timelord_dispatcher())
            await asyncio.sleep(0)
            stop1.cancel()
            await asyncio.sleep(0)
            stop1.cancel()
            assert not stop1.done() and not stop2.done()
            server.release.set()
            await asyncio.gather(completion1, completion2)
            stopped = await asyncio.gather(stop1, stop2, return_exceptions=True)
            assert isinstance(stopped[0], asyncio.CancelledError) and stopped[1] is None
            assert node._timelord_post_commit_task is None
            assert node._timelord_post_commit_queue is not None
            assert node._timelord_post_commit_queue.empty()
            assert server.messages == [
                (message1, NodeType.FULL_NODE), (message1, NodeType.FARMER),
                (message2, NodeType.FULL_NODE), (message2, NodeType.FARMER),
            ]
        finally:
            server.release.set()


@pytest.mark.anyio
async def test_publication_failure_does_not_suppress_farmer(tmp_path: Path) -> None:
    server = BlockingServer()
    node = make_node(tmp_path, server)

    async def fail_full_nodes(messages: list[Message], node_type: NodeType, *args: Any) -> None:
        if node_type is NodeType.FULL_NODE:
            raise OSError("network unavailable")
        server.messages.extend((message, node_type) for message in messages)

    payload = make_farmer_payload()
    message = make_msg(ProtocolMessageTypes.new_signage_point, payload)
    server.send_to_all = fail_full_nodes  # type: ignore[method-assign]
    await node.publish_signage_point(SignagePointPublishPlan(message, message, payload, std_hash(b"peer")))
    assert server.messages == [(message, NodeType.FARMER)]