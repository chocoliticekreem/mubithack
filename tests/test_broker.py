"""Queue and lease semantics for `forge orchestrate`: no double-booking, priority/deps order, crash recovery."""

import threading

from forge.broker import Broker, JobQueue, StudioSlots


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


def _broker(tmp_path, pools=None, *, alive=lambda pid: True, clock=None, slots=None):
    return Broker(tmp_path / "broker", pools or {"studio": ["Forge-agents-30"], "llm": ["llm-1", "llm-2"],
                                                  "sync": ["34901"], "game": ["game:g"]},
                  alive=alive, clock=clock or Clock(), studio_slots=slots)


def test_studio_is_never_double_booked(tmp_path):
    b = _broker(tmp_path)
    a = b.try_acquire(["studio", "sync", "llm"], holder="job-a", pid=1)
    assert a and {ls["pool"] for ls in a} == {"studio", "sync", "llm"}
    assert b.try_acquire(["studio", "llm"], holder="job-b", pid=1) is None
    # all-or-nothing: job-b got nothing, so both llm slots minus job-a's one are still free
    assert len(b.held("llm")) == 1
    assert b.try_acquire(["llm"], holder="job-c", pid=1)
    b.release("job-a")
    assert b.try_acquire(["studio"], holder="job-b", pid=1)


def test_concurrent_acquires_never_share_a_slot(tmp_path):
    b = _broker(tmp_path, {"studio": ["s1", "s2"]})
    got: list = []
    lock = threading.Lock()

    def grab(i):
        res = b.try_acquire(["studio"], holder=f"j{i}", pid=1)
        if res:
            with lock:
                got.append(res[0]["slot"])

    threads = [threading.Thread(target=grab, args=(i,)) for i in range(12)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(got) == ["s1", "s2"]


def test_stale_lease_is_reclaimed(tmp_path):
    clock = Clock()
    dead = {111}
    b = _broker(tmp_path, alive=lambda pid: pid not in dead, clock=clock)
    assert b.try_acquire(["studio"], holder="crashed", pid=111)
    # the holder process is gone: the next acquire takes the slot back
    assert b.try_acquire(["studio"], holder="next", pid=222)
    # a live holder that stops heartbeating loses its lease after the ttl
    b.release("next")
    assert b.try_acquire(["studio"], holder="slow", pid=222)
    clock.t += b.ttl + 1
    assert b.try_acquire(["studio"], holder="other", pid=333)


def test_renew_keeps_a_lease(tmp_path):
    clock = Clock()
    b = _broker(tmp_path, clock=clock)
    b.try_acquire(["studio"], holder="long", pid=1)
    for _ in range(5):
        clock.t += b.ttl / 2
        assert b.renew("long") == 1
        assert b.try_acquire(["studio"], holder="other", pid=1) is None


def test_studio_lease_takes_a_machine_slot(tmp_path):
    slots = StudioSlots(tmp_path / "slots", max_slots=1, running=lambda name: True)
    assert slots.try_acquire("someone-else")  # another agent's window holds the only slot
    b = _broker(tmp_path, slots=slots)
    assert b.try_acquire(["studio", "llm"], holder="j", pid=1) is None
    assert not b.held()  # nothing kept from the failed all-or-nothing acquire
    slots.release("someone-else")
    assert b.try_acquire(["studio"], holder="j", pid=1)
    assert slots.held_by("Forge-agents-30") == "slot1"


def test_studio_slots_reclaim_like_the_shell_script(tmp_path):
    clock = Clock(10_000_000_000.0)
    slots = StudioSlots(tmp_path / "slots", max_slots=1, running=lambda name: False, clock=clock)
    assert slots.try_acquire("gone-window") == "slot1"
    assert slots.try_acquire("me") == "slot1"  # owner's window is not running and the slot is > 2 min old
    assert slots.owners() == {"slot1": "me"}


def test_queue_orders_by_priority_then_fifo(tmp_path):
    q = JobQueue(tmp_path / "q")
    low = q.add("feature", "low", priority=1)
    high = q.add("feature", "high", priority=9)
    high2 = q.add("feature", "high too", priority=9)
    order = [q.claim("w")[0]["id"] for _ in range(3)]
    assert order == [high["id"], high2["id"], low["id"]]
    assert q.claim("w") is None


def test_deps_wait_and_failed_deps_skip(tmp_path):
    q = JobQueue(tmp_path / "q")
    build = q.add("feature", "build", priority=1)
    play = q.add("playtest", "play", priority=50, deps=[build["id"]])
    after = q.add("verify", "verify", priority=40, after=[build["id"]])
    job, _ = q.claim("w")
    assert job["id"] == build["id"]  # the high-priority jobs wait for their dependency
    assert q.claim("w") is None
    q.finish(build["id"], False, error="boom")
    assert q.get(play["id"])["status"] == "skipped"  # needs success
    job, _ = q.claim("w")
    assert job["id"] == after["id"]  # `after` only needs the build to be finished


def test_studio_job_waits_while_llm_jobs_flow(tmp_path):
    b = _broker(tmp_path)
    q = JobQueue(tmp_path / "q")
    b.try_acquire(["studio"], holder="someone", pid=1)
    studio_job = q.add("playtest", "needs studio", priority=10, needs=["studio", "llm"])
    llm_job = q.add("gaps", "llm only", priority=1, needs=["llm"])
    job, leases = q.claim("w1", b)
    assert job["id"] == llm_job["id"] and leases[0]["pool"] == "llm"
    assert q.get(studio_job["id"])["status"] == "queued"  # waiting, not failed
    b.release("someone")
    job, leases = q.claim("w2", b)
    assert job["id"] == studio_job["id"]
    assert {ls["pool"] for ls in leases} == {"studio", "llm"}


def test_crashed_worker_job_is_recovered(tmp_path):
    clock = Clock()
    dead = {4242}
    b = _broker(tmp_path, alive=lambda pid: pid not in dead, clock=clock)
    q = JobQueue(tmp_path / "q", alive=lambda pid: pid not in dead, clock=clock)
    j = q.add("playtest", "play", needs=["studio"], max_attempts=2)
    job, _ = q.claim("w1", b, pid=4242)  # this worker then crashes
    assert job["status"] == "running"
    lost = q.recover(b)
    assert [x["id"] for x in lost] == [j["id"]]
    assert q.get(j["id"])["status"] == "queued"
    assert not b.held("studio")  # its lease is gone too
    job, _ = q.claim("w2", b, pid=5555)
    assert job["id"] == j["id"] and job["attempts"] == 2
    dead.add(5555)
    q.recover(b)
    assert q.get(j["id"])["status"] == "failed"  # out of attempts


def test_silent_worker_is_recovered_after_stale_window(tmp_path):
    clock = Clock()
    q = JobQueue(tmp_path / "q", alive=lambda pid: True, clock=clock, stale_after=60)
    j = q.add("feature", "x")
    q.claim("w", pid=1)
    clock.t += 30
    q.heartbeat(j["id"])
    clock.t += 50
    assert q.recover() == []
    clock.t += 61
    assert q.recover()[0]["id"] == j["id"]


def test_two_workers_never_claim_the_same_job(tmp_path):
    q = JobQueue(tmp_path / "q")
    for i in range(20):
        q.add("feature", f"j{i}")
    claimed: list = []
    lock = threading.Lock()

    def work(name):
        while True:
            got = q.claim(name)
            if not got:
                return
            with lock:
                claimed.append(got[0]["id"])

    ts = [threading.Thread(target=work, args=(f"w{i}",)) for i in range(4)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert len(claimed) == 20 and len(set(claimed)) == 20


def test_retry_then_fail_and_cancel(tmp_path):
    q = JobQueue(tmp_path / "q")
    j = q.add("playtest", "p", max_attempts=2)
    other = q.add("feature", "f", priority=-1)
    q.claim("w")
    assert q.retry_or_fail(j["id"], "studio not connected")["status"] == "queued"
    q.claim("w")
    assert q.retry_or_fail(j["id"], "studio not connected")["status"] == "failed"
    assert q.cancel_pending("budget") == 1
    assert q.get(other["id"])["status"] == "cancelled"
    assert q.idle()


def test_shared_slots_file_locks_and_exclusive_holds(tmp_path):
    b = _broker(tmp_path, {"game": ["g#1", "g#2", "g#3"]})
    a = b.try_acquire(["game", "lock:A.luau"], holder="fix-a", pid=1)
    assert a and {ls["pool"] for ls in a} == {"game", "lock:A.luau"}
    assert b.try_acquire(["game", "lock:A.luau"], holder="fix-a2", pid=1) is None  # same file: waits
    assert b.last_blocked == "lock:A.luau"
    assert b.try_acquire(["game", "lock:B.luau"], holder="fix-b", pid=1)  # other file: in parallel
    assert b.try_acquire(["game:all"], holder="feature", pid=1) is None  # whole-game writer waits
    assert b.last_blocked == "game"
    b.release("fix-a")
    b.release("fix-b")
    got = b.try_acquire(["game:all"], holder="feature", pid=1)
    assert sorted(ls["slot"] for ls in got) == ["g#1", "g#2", "g#3"]
    assert b.try_acquire(["game", "lock:C.luau"], holder="fix-c", pid=1) is None


def test_a_waiting_high_priority_job_is_not_starved(tmp_path):
    b = _broker(tmp_path, {"game": ["g#1", "g#2"], "llm": ["l1", "l2", "l3", "l4"]})
    q = JobQueue(tmp_path / "q")
    b.try_acquire(["game", "lock:X"], holder="running-fix", pid=1)  # a fix already holds one game slot
    q.add("feature", "big", priority=9, needs=["llm", "game:all"])
    small = q.add("fix", "small", priority=1, needs=["llm", "game", "lock:Y"])
    other = q.add("gaps", "gap finder", priority=0.5, needs=["llm"])
    job, _ = q.claim("w", b)
    # the small fix could start (a game slot is free), but the big job is waiting for the game: it doesn't
    assert job["id"] == other["id"]
    assert q.get(small["id"])["status"] == "queued"
    b.release("running-fix")
    job, leases = q.claim("w", b)
    assert job["title"] == "big" and {ls["slot"] for ls in leases if ls["pool"] == "game"} == {"g#1", "g#2"}


def test_finish_can_settle_a_follow_up_job(tmp_path):
    q = JobQueue(tmp_path / "q")
    first = q.add("checks_offline", "headless", priority=2)
    studio = q.add("checks", "studio checks", priority=1, deps=[first["id"]], needs=["studio"])
    q.update_args(first["id"], studio_job=studio["id"])
    assert q.get(first["id"])["args"]["studio_job"] == studio["id"]
    q.claim("w")
    q.finish(first["id"], True, {"n": 1}, also_done={studio["id"]: {"skipped": "all passed headless"}})
    assert q.get(studio["id"])["status"] == "done" and q.claim("w") is None
