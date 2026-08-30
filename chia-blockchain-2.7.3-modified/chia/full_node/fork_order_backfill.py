from __future__ import annotations

from chia_rs import ConsensusConstants
from chia_rs.sized_bytes import bytes32
from chia_rs.sized_ints import uint64

from chia.consensus.blockchain import Blockchain
from chia.consensus.fork_order import FORK_ORDER_KEY_VERSION, calculate_fork_tie_key
from chia.consensus.get_block_challenge import get_block_challenge, pre_sp_tx_block_height
from chia.consensus.pot_iterations import is_overflow_block, validate_pospace_and_get_quality_and_iters
from chia.full_node.block_store import BlockStore


async def backfill_fork_order_keys(
    blockchain: Blockchain,
    block_store: BlockStore,
    constants: ConsensusConstants,
    *,
    batch_size: int = 100,
) -> int:
    """Revalidate and backfill missing post-activation fork-order keys.

    The operation is idempotent and commits bounded batches. It is intended to
    run before a node makes post-activation peak decisions.
    """

    pending: list[tuple[bytes32, bytes32]] = []
    written = 0

    async def flush() -> None:
        nonlocal written
        if not pending:
            return
        async with block_store.transaction():
            for header_hash, tie_key in pending:
                await block_store.set_fork_order_key(
                    header_hash,
                    tie_key,
                    key_version=FORK_ORDER_KEY_VERSION,
                )
        written += len(pending)
        pending.clear()

    async for full_block, block_record in block_store.iter_full_blocks_from_height(
        constants.FORK_TIE_BREAK_HEIGHT,
        batch_size=batch_size,
    ):
        if await block_store.get_fork_order_key(block_record.header_hash) is not None:
            continue

        prev_block = None
        if block_record.height > 0:
            prev_block = await blockchain.get_block_record_from_db(block_record.prev_hash)
            if prev_block is None:
                raise RuntimeError(f"missing previous block for fork-order backfill: {block_record.prev_hash}")
            if blockchain.try_block_record(prev_block.header_hash) is None:
                blockchain.add_block_record(prev_block)

        overflow = is_overflow_block(constants, full_block.reward_chain_block.signage_point_index)
        challenge = get_block_challenge(
            constants,
            full_block,
            blockchain,
            prev_block is None,
            overflow,
            False,
        )
        if full_block.reward_chain_block.challenge_chain_sp_vdf is None:
            cc_sp_hash = challenge
        else:
            cc_sp_hash = full_block.reward_chain_block.challenge_chain_sp_vdf.output.get_hash()

        difficulty = uint64(
            int(block_record.weight) if prev_block is None else int(block_record.weight) - int(prev_block.weight)
        )
        pospace_result = validate_pospace_and_get_quality_and_iters(
            constants,
            full_block.reward_chain_block.proof_of_space,
            challenge,
            cc_sp_hash,
            block_record.height,
            difficulty,
            pre_sp_tx_block_height(
                constants=constants,
                blocks=blockchain,
                prev_b_hash=full_block.prev_header_hash,
                sp_index=full_block.reward_chain_block.signage_point_index,
                finished_sub_slots=len(full_block.finished_sub_slots),
            ),
        )
        if pospace_result is None or pospace_result.required_iters != block_record.required_iters:
            raise RuntimeError(f"stored block failed proof validation: {block_record.header_hash}")

        pending.append(
            (
                block_record.header_hash,
                calculate_fork_tie_key(
                    block_record,
                    full_block.reward_chain_block.proof_of_space,
                    pospace_result.quality,
                ),
            )
        )
        if len(pending) >= batch_size:
            await flush()

    await flush()
    return written
