from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import logging
import time
from collections import Counter
from collections.abc import AsyncIterator

from chia_rs import ConsensusConstants
from chia_rs.sized_bytes import bytes32

from chia.full_node.signage_point_validation import PreparedSignagePoint, SPVerifyStatus, verify_prepared_signage_point
from chia.util.limited_semaphore import LimitedSemaphore, LimitedSemaphoreFullError
from chia.util.priority_thread_pool_executor import PriorityThreadPoolExecutor
from chia.util.task_referencer import create_referenced_task

SP_VALIDATION_WORKERS = 1
SP_VALIDATION_WAITING_LIMIT = 8
SP_VALIDATION_CAPACITY = SP_VALIDATION_WORKERS + SP_VALIDATION_WAITING_LIMIT


class SignagePointPeerBusy(Exception):
    pass


class SignagePointValidationError(Exception):
    """Local worker failure, not evidence of invalid peer input."""


@dataclasses.dataclass
class SignagePointValidationBroker:
    """One process-wide native-work budget, also retained when every caller disconnects."""

    constants: ConsensusConstants
    log: logging.Logger
    _pool: PriorityThreadPoolExecutor
    _work_sem: LimitedSemaphore = dataclasses.field(
        default_factory=lambda: LimitedSemaphore.create(SP_VALIDATION_WORKERS, SP_VALIDATION_WAITING_LIMIT)
    )
    _handler_sem: LimitedSemaphore = dataclasses.field(
        default_factory=lambda: LimitedSemaphore.create(SP_VALIDATION_CAPACITY, 0)
    )
    _inflight: dict[bytes32, tuple[PreparedSignagePoint, asyncio.Task[SPVerifyStatus]]] = dataclasses.field(
        default_factory=dict
    )
    _handlers: set[bytes32] = dataclasses.field(default_factory=set)
    _peer_jobs: dict[bytes32, bytes32] = dataclasses.field(default_factory=dict)
    _closed: bool = False
    _close_task: asyncio.Task[None] | None = None
    active: int = 0
    results: Counter[str] = dataclasses.field(default_factory=Counter)

    @classmethod
    @contextlib.asynccontextmanager
    async def managed(
        cls, constants: ConsensusConstants, log: logging.Logger
    ) -> AsyncIterator[SignagePointValidationBroker]:
        broker = cls(
            constants, log,
            PriorityThreadPoolExecutor(max_workers=SP_VALIDATION_WORKERS, thread_name_prefix="sp-vdf-"),
        )
        try:
            yield broker
        finally:
            await broker.close()

    @property
    def waiting(self) -> int:
        return len(self._inflight) - self.active

    @contextlib.asynccontextmanager
    async def admit(self, peer_id: bytes32, digest: bytes32) -> AsyncIterator[None]:
        # No waiting handler tasks: this also bounds prefetches and coalesced waiters.
        if self._closed:
            raise LimitedSemaphoreFullError
        if peer_id in self._handlers or self._peer_jobs.get(peer_id, digest) != digest:
            raise SignagePointPeerBusy
        async with self._handler_sem.acquire():
            self._handlers.add(peer_id)
            try:
                yield
            finally:
                self._handlers.remove(peer_id)

    async def verify(
        self, digest: bytes32, prepared: PreparedSignagePoint, peer_id: bytes32
    ) -> SPVerifyStatus:
        if self._closed:
            raise LimitedSemaphoreFullError
        existing = self._inflight.get(digest)
        if existing is not None and existing[0].context != prepared.context:
            # Never reuse a proof result for a different start element/chain context.
            raise SignagePointPeerBusy
        if peer_id not in self._peer_jobs and len(self._peer_jobs) >= SP_VALIDATION_CAPACITY:
            raise LimitedSemaphoreFullError
        if self._peer_jobs.get(peer_id, digest) != digest:
            raise SignagePointPeerBusy
        if existing is None:
            if len(self._inflight) >= SP_VALIDATION_CAPACITY:
                raise LimitedSemaphoreFullError
            self._peer_jobs[peer_id] = digest
            task = create_referenced_task(self._run(digest, prepared))
            # Retrieve failures even if every shielded caller has disconnected.
            task.add_done_callback(self._observe_completion)
            self._inflight[digest] = prepared, task
        else:
            self.results["coalesced"] += 1
            self._peer_jobs[peer_id] = digest
            task = existing[1]
        # A waiter never owns the permit or cancels the native job.
        return await asyncio.shield(task)

    @staticmethod
    def _observe_completion(task: asyncio.Task[SPVerifyStatus]) -> None:
        if not task.cancelled():
            task.exception()

    async def _run(self, digest: bytes32, prepared: PreparedSignagePoint) -> SPVerifyStatus:
        try:
            async with self._work_sem.acquire():
                self.active += 1
                started = time.monotonic()
                try:
                    future = self._pool.run_in_loop(verify_prepared_signage_point, self.constants, prepared)
                    cancelled = False
                    while True:
                        try:
                            result: SPVerifyStatus = await asyncio.shield(future)
                            break
                        except asyncio.CancelledError:
                            # Retain the permit even under repeated cancellation until native completion.
                            cancelled = True
                    if cancelled:
                        raise asyncio.CancelledError
                    self.results[f"verify_{result.value}"] += 1
                    return result
                finally:
                    self.active -= 1
                    self.log.debug("SP verification %s took %.6fs", digest.hex()[:12], time.monotonic() - started)
        except Exception as error:
            self.results["executor_failure"] += 1
            self.log.exception("SP verification worker failed: %s", digest.hex()[:12])
            raise SignagePointValidationError from error
        finally:
            self._inflight.pop(digest, None)
            for peer_id, job_digest in list(self._peer_jobs.items()):
                if job_digest == digest:
                    del self._peer_jobs[peer_id]

    async def close(self) -> None:
        self._closed = True
        if self._close_task is None:
            self._close_task = create_referenced_task(self._drain())
        cancelled = False
        while True:
            try:
                await asyncio.shield(self._close_task)
                break
            except asyncio.CancelledError:
                cancelled = True
        if cancelled:
            raise asyncio.CancelledError

    async def _drain(self) -> None:
        # Drain rather than cancel: queued/running jobs keep their accounting until completion.
        await asyncio.gather(*(job[1] for job in tuple(self._inflight.values())), return_exceptions=True)
        await asyncio.to_thread(self._pool.shutdown)