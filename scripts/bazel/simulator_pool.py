"""Isolated XCTest devices cloned from a bounded cache of prepared blank devices."""
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import tempfile
import time
import uuid


MAX_SEEDS = 4


def pool_directory():
    return Path(pwd.getpwuid(os.getuid()).pw_dir) / "Library/Application Support/NuxieBuild/Simulators"


def simctl(arguments):
    result = subprocess.run(["/usr/bin/xcrun", "simctl", *arguments], check=True,
                            stdout=subprocess.PIPE, text=True, timeout=180)
    return result.stdout.strip()


def process_identity(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                            capture_output=True, text=True, timeout=30,
                            env={**os.environ, "TZ": "UTC", "LC_ALL": "C"})
    if result.returncode == 1 and not result.stdout.strip():
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return None
        raise RuntimeError("live simulator owner birth observation unavailable")
    result.check_returncode()
    return result.stdout.strip() or None


def process_sample():
    rows = {}
    for line in subprocess.check_output(["/bin/ps", "-axo", "pid,ppid,time,command"], text=True, timeout=30).splitlines()[1:]:
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        duration = fields[2]; days, _, duration = duration.rpartition("-") if "-" in duration else ("0", "", duration)
        seconds = int(days) * 86400
        for power, part in enumerate(reversed(duration.split(":"))):
            seconds += float(part) * 60 ** power
        rows[int(fields[0])] = (int(fields[1]), seconds, fields[3])
    return rows


def device_processes(identifier, rows):
    owned = {pid for pid, (_, _, command) in rows.items()
             if command.startswith("launchd_sim ") and "/Devices/" + identifier + "/" in command}
    while True:
        children = {pid for pid, row in rows.items() if row[0] in owned} - owned
        if not children:
            return owned
        owned.update(children)


def device_in_use(identifier):
    rows = process_sample()
    for _, _, command in rows.values():
        if ((re.search(r"(?:^|\s)(?:[^\s]*/)?xcodebuild(?:\s|$)", command) and "id=" + identifier in command)
                or (re.search(r"(?:^|\s)(?:[^\s]*/)?simctl\s", command) and identifier in command)):
            return True
    # A cancelled host runner can leave XCTest alive inside launchd_sim.
    return any(re.search(r"(?:^|[/\s])(?:xctest|[^/\s]*XCTRunner|[^/\s]*-Runner)(?:\s|$)|\.xctest/", rows[pid][2])
               for pid in device_processes(identifier, rows))


def cpu_sample(identifier):
    rows = process_sample()
    owned = device_processes(identifier, rows)
    if not owned:
        raise RuntimeError("prepared simulator launchd observation unavailable")
    return {pid: rows[pid][1] for pid in owned}


def wait_quiet(identifier, timeout=180):
    started = time.monotonic(); previous = None; sampled_at = None; quiet = 0
    while time.monotonic() - started < timeout:
        try:
            current = cpu_sample(identifier)
        except subprocess.TimeoutExpired:
            # A transient host stall is not proof of an unhealthy device.
            # Keep the boot queue owned and start a fresh quiet window.
            previous = None; quiet = 0
            print("Simulator process observation is slow; waiting for a fresh quiet window", file=sys.stderr, flush=True)
            continue
        observed = time.monotonic()
        if previous is not None:
            used = sum(max(0, value - previous.get(pid, 0)) for pid, value in current.items())
            quiet = quiet + 1 if used / max(observed - sampled_at, .001) < .75 else 0
            if quiet >= 5:
                return
        previous = current; sampled_at = observed
        time.sleep(1)
    raise TimeoutError("simulator first-boot services did not settle within 180s")


def developer_identity():
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(
        ["/usr/bin/xcode-select", "-p"], text=True, timeout=30).strip()
    info = Path(developer).parent / "Info.plist"
    return hashlib.sha256(str(developer).encode() + info.read_bytes()).hexdigest()


class Pool:
    def __init__(self, root=None, *, control=simctl, identity=process_identity,
                 quiet=wait_quiet, in_use=device_in_use, developer=developer_identity):
        self.root = pool_directory() if root is None else root
        self.control, self.identity, self.quiet = control, identity, quiet
        self.in_use, self.developer = in_use, developer
        for path in (self.root, self.root / "seeds", self.root / "leases"):
            path.mkdir(mode=0o700, parents=True, exist_ok=True)
            info = path.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError("private owned simulator pool directories required")

    @contextmanager
    def lock(self):
        fd = os.open(self.root / "boot.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o077:
                raise ValueError("private owned simulator boot lock required")
            started = time.monotonic(); announced = -1
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); break
                except BlockingIOError:
                    elapsed = time.monotonic() - started
                    if elapsed > 600:
                        raise TimeoutError("simulator preparation queue exceeded 600s")
                    if int(elapsed // 5) != announced:
                        print("Simulator preparation queued %.1fs; another device is booting" % elapsed, file=sys.stderr, flush=True)
                        announced = int(elapsed // 5)
                    time.sleep(.2)
            yield
        finally:
            os.close(fd)

    def write(self, path, value):
        with tempfile.NamedTemporaryFile(dir=path.parent, mode="w", delete=False) as stream:
            pending = Path(stream.name)
            try:
                json.dump(value, stream); stream.flush(); pending.replace(path)
            finally:
                pending.unlink(missing_ok=True)

    def read(self, path):
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("private owned simulator receipt required")
        return json.loads(path.read_text())

    def inventory(self):
        return json.loads(self.control(["list", "-j"]))

    def device(self, record):
        matches = [device for runtime, devices in self.inventory()["devices"].items()
                   for device in devices if runtime == record["runtime"] and device["name"] == record["name"]
                   and (not record.get("udid") or device["udid"] == record["udid"])]
        if len(matches) > 1:
            raise ValueError("ambiguous owned simulator identity")
        return matches[0] if matches else None

    def remove(self, path, record):
        if self.in_use(record.get("udid") or record["name"]):
            return False
        device = self.device(record)
        if device:
            if self.in_use(device["udid"]):
                return False
            self.control(["delete", device["udid"]])
            if self.device(record):
                raise RuntimeError("owned simulator deletion was not verified")
        path.unlink(missing_ok=True)
        return True

    def discard_failed_preparation(self, path, record):
        try:
            self.remove(path, record)
        except Exception as error:
            print("Simulator preparation cleanup deferred: " + str(error), file=sys.stderr, flush=True)

    def reap(self):
        for path in (self.root / "leases").glob("*.json"):
            record = self.read(path)
            if self.identity(record["ownerPid"]) != record["ownerBirth"]:
                self.remove(path, record)

    def boot(self, identifier):
        self.control(["bootstatus", identifier, "-b"])
        self.quiet(identifier)

    def seed(self, key, runtime, device_type):
        path = self.root / "seeds" / (key + ".json")
        if path.exists():
            record = self.read(path); device = self.device(record)
            if record.get("ready") and device and device["state"] == "Shutdown":
                record["lastUsed"] = time.time(); self.write(path, record)
                return record["udid"]
            if record.get("ready") and device:
                raise RuntimeError("prepared blank simulator is unexpectedly in use")
            if not self.remove(path, record):
                raise RuntimeError("incomplete blank simulator preparation is still in use")
        seeds = sorted(((self.read(p).get("lastUsed", 0), p) for p in (self.root / "seeds").glob("*.json")))
        while len(seeds) >= MAX_SEEDS:
            _, oldest = seeds.pop(0)
            if not self.remove(oldest, self.read(oldest)):
                raise RuntimeError("old blank simulator is still in use")
        record = {"name": "NuxieSDKBlank-" + uuid.uuid4().hex, "runtime": runtime, "ready": False}
        self.write(path, record)
        try:
            record["udid"] = self.control(["create", record["name"], device_type, runtime])
            self.write(path, record)
            print("Preparing blank iOS simulator once for this Xcode/runtime/viewport", file=sys.stderr, flush=True)
            self.boot(record["udid"])
            self.control(["shutdown", record["udid"]])
            deadline = time.monotonic() + 15
            while self.device(record)["state"] != "Shutdown":
                if time.monotonic() >= deadline:
                    raise TimeoutError("blank simulator shutdown did not complete")
                time.sleep(.2)
            record.update(ready=True, lastUsed=time.time()); self.write(path, record)
            return record["udid"]
        except BaseException:
            self.discard_failed_preparation(path, record)
            raise

    def create(self, version, device_type, owner):
        if type(owner) is not int or owner <= 1:
            raise ValueError("live Apple test runner identity required")
        birth = self.identity(owner)
        if not birth:
            raise ValueError("live Apple test runner identity required")
        with self.lock():
            if self.identity(owner) != birth:
                raise RuntimeError("Apple test runner ended while queued for simulator preparation")
            self.reap()
            runtime = next((r for r in self.inventory()["runtimes"]
                            if r.get("isAvailable") and r["version"] == version and ".iOS-" in r["identifier"]), None)
            if runtime is None:
                raise ValueError("requested iOS runtime is unavailable")
            key = hashlib.sha256(json.dumps([self.developer(), runtime["identifier"], runtime["buildversion"],
                                            device_type], separators=(",", ":")).encode()).hexdigest()
            seed = self.seed(key, runtime["identifier"], device_type)
            token = uuid.uuid4().hex; path = self.root / "leases" / (token + ".json")
            record = {"name": "NuxieSDKTest-" + token, "runtime": runtime["identifier"],
                      "ownerPid": owner, "ownerBirth": birth}
            self.write(path, record)
            try:
                record["udid"] = self.control(["clone", seed, record["name"]]); self.write(path, record)
                self.boot(record["udid"])
                if self.identity(owner) != birth:
                    raise RuntimeError("Apple test runner ended during simulator preparation")
                print("Isolated simulator ready from prepared blank device", file=sys.stderr, flush=True)
                return record["udid"]
            except BaseException:
                self.discard_failed_preparation(path, record)
                raise

    def cleanup(self, identifier, owner):
        with self.lock():
            for path in (self.root / "leases").glob("*.json"):
                record = self.read(path)
                if record.get("udid") == identifier:
                    if record["ownerPid"] != owner or self.identity(owner) != record["ownerBirth"]:
                        raise ValueError("simulator belongs to another test runner")
                    return self.remove(path, record)
            raise ValueError("simulator is not owned by this controller")


def main(operation):
    owner = int(os.environ["SIMULATOR_RUNNER_PID"])
    pool = Pool()
    if operation == "create":
        print(pool.create(os.environ["SIMULATOR_OS_VERSION"], os.environ["SIMULATOR_DEVICE_TYPE"], owner))
    else:
        if not pool.cleanup(os.environ["SIMULATOR_UDID"], owner):
            print("Simulator cleanup deferred until its XCTest process ends", file=sys.stderr)
