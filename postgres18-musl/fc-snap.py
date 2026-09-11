#!/usr/bin/env python3
# Snapshot-capable Firecracker driver for OSv+PG.
# Modes:
#   boot     : boot OSv+PG via the API socket (drives + tap net), leave running.
#   snapshot : pause a running VM and write a Full snapshot (vmstate + mem).
#   restore  : from a NEW fc process, load a snapshot and resume the VM.
#
# Uses the FC HTTP API over a unix socket (requests via requests_unixsocket-free
# raw http over AF_UNIX with the stdlib). Config mirrors fc-run.py's device order.
import argparse, json, os, socket, subprocess, sys, time

FC = "/usr/local/bin/firecracker"
OSV = os.environ.get("OSV", os.path.expanduser("~/osv")) + "/build/last"
KERNEL = OSV + "/loader-stripped.elf"
ROOTFS = OSV + "/usr.raw"
GUEST_IP = "192.168.100.2"; GW = "192.168.100.1"; TAP = "fc_tap0"
MAC = "52:54:00:12:34:56"

def http_unix(sock_path, method, path, body=None, tries=200):
    """Minimal HTTP/1.1 over AF_UNIX. Returns (status, body_str)."""
    data = json.dumps(body) if body is not None else None
    for _ in range(tries):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(sock_path); break
        except (FileNotFoundError, ConnectionRefusedError):
            time.sleep(0.02)
    else:
        raise RuntimeError("FC socket never came up: %s" % sock_path)
    req = "%s %s HTTP/1.1\r\nHost: localhost\r\nAccept: application/json\r\n" % (method, path)
    if data is not None:
        req += "Content-Type: application/json\r\nContent-Length: %d\r\n" % len(data)
    req += "\r\n"
    if data is not None:
        req += data
    s.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = s.recv(65536)
        if not chunk: break
        resp += chunk
    head, _, rest = resp.partition(b"\r\n\r\n")
    status = int(head.split(b" ")[1])
    # read body per content-length if present
    clen = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            clen = int(line.split(b":")[1])
    while len(rest) < clen:
        rest += s.recv(65536)
    s.close()
    return status, rest.decode(errors="replace")

def api(sock, method, path, body=None, ok=(200, 204)):
    st, b = http_unix(sock, method, path, body)
    if st not in ok:
        raise RuntimeError("FC API %s %s -> %d: %s" % (method, path, st, b))
    return st, b

def start_fc(sock, logf):
    if os.path.exists(sock): os.unlink(sock)
    lf = open(logf, "w")
    p = subprocess.Popen([FC, "--api-sock", sock], stdout=lf, stderr=subprocess.STDOUT)
    return p

def do_boot(a):
    global KERNEL, ROOTFS
    if a.kernel: KERNEL = a.kernel
    if a.rootfs: ROOTFS = a.rootfs
    cmdline = a.append
    if a.net:
        cmdline = "--ip=eth0,%s,255.255.255.0 --defaultgw=%s %s" % (GUEST_IP, GW, cmdline)
    cmdline = "--nopci " + cmdline
    p = start_fc(a.socket, a.fclog)
    # machine-config
    api(a.socket, "PUT", "/machine-config",
        {"vcpu_count": a.vcpus, "mem_size_mib": a.mem, "smt": False})
    api(a.socket, "PUT", "/boot-source",
        {"kernel_image_path": KERNEL, "boot_args": cmdline})
    # drives: rootfs then members
    api(a.socket, "PUT", "/drives/rootfs",
        {"drive_id": "rootfs", "path_on_host": ROOTFS,
         "is_root_device": False, "is_read_only": False})
    members = [m for m in a.members.split(",") if m]
    for i, m in enumerate(members, start=1):
        api(a.socket, "PUT", "/drives/blk%d" % i,
            {"drive_id": "blk%d" % i, "path_on_host": m,
             "is_root_device": False, "is_read_only": False})
    if a.net:
        api(a.socket, "PUT", "/network-interfaces/eth0",
            {"iface_id": "eth0", "host_dev_name": TAP, "guest_mac": MAC})
    api(a.socket, "PUT", "/actions", {"action_type": "InstanceStart"})
    print("BOOTED pid=%d sock=%s" % (p.pid, a.socket), flush=True)
    with open(a.pidfile, "w") as f: f.write(str(p.pid))
    if a.wait:
        try: p.wait()
        except KeyboardInterrupt: p.terminate()

def do_snapshot(a):
    # pause, then Full snapshot
    t0 = time.time()
    api(a.socket, "PATCH", "/vm", {"state": "Paused"})
    tp = time.time()
    api(a.socket, "PUT", "/snapshot/create",
        {"snapshot_type": "Full",
         "snapshot_path": a.snap_vmstate,
         "mem_file_path": a.snap_mem})
    ts = time.time()
    print("PAUSE=%.3fs SNAPSHOT_WRITE=%.3fs TOTAL=%.3fs" % (tp - t0, ts - tp, ts - t0), flush=True)
    if a.resume_after:
        api(a.socket, "PATCH", "/vm", {"state": "Resumed"})
        print("RESUMED-after-snapshot", flush=True)

def do_restore(a):
    # NEW fc process; load snapshot and resume.
    p = start_fc(a.socket, a.fclog)
    t0 = time.time()
    body = {
        "snapshot_path": a.snap_vmstate,
        "mem_backend": {"backend_type": "File", "backend_path": a.snap_mem},
        "enable_diff_snapshots": False,
        "resume_vm": True,
    }
    api(a.socket, "PUT", "/snapshot/load", body)
    t1 = time.time()
    print("RESTORE_RESUME=%.3fs pid=%d T1(fc-resume-return)=%.6f" % (t1 - t0, p.pid, t1), flush=True)
    with open(a.pidfile, "w") as f: f.write(str(p.pid))
    # emit T0/T1 epochs for external measurement harness
    with open(a.tstamp, "w") as f:
        f.write("T0 %.6f\nT1 %.6f\n" % (t0, t1))
    if a.wait:
        try: p.wait()
        except KeyboardInterrupt: p.terminate()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["boot", "snapshot", "restore"])
    ap.add_argument("--append", default="")
    ap.add_argument("--vcpus", type=int, default=8)
    ap.add_argument("--mem", type=int, default=16384)
    ap.add_argument("--net", action="store_true")
    ap.add_argument("--members", default="")
    ap.add_argument("--socket", default="/tmp/fc.sock")
    ap.add_argument("--fclog", default="/tmp/fc-console.log")
    ap.add_argument("--pidfile", default="/tmp/fc.pid")
    ap.add_argument("--snap-vmstate", default="/tmp/snap/osvpg.vmstate")
    ap.add_argument("--snap-mem", default="/tmp/snap/osvpg.mem")
    ap.add_argument("--tstamp", default="/tmp/fc-restore.tstamp")
    ap.add_argument("--wait", action="store_true")
    ap.add_argument("--resume-after", action="store_true")
    ap.add_argument("--kernel", default="")
    ap.add_argument("--rootfs", default="")
    a = ap.parse_args()
    {"boot": do_boot, "snapshot": do_snapshot, "restore": do_restore}[a.mode](a)

if __name__ == "__main__":
    main()
