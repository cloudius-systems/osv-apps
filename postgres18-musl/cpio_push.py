#!/usr/bin/python3
# Push a host directory tree into a running OSv cpiod over TCP (cpio-newc).
# Usage: cpio_push.py <src_dir> <host> <port>
# Files are sent with paths relative to src_dir, rooted at '/', so with cpiod
# --prefix /data/ the tree lands under /data/.
import os, sys, socket, stat, time

src, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])

# connect (retry until cpiod is listening)
s = None
for _ in range(120):
    try:
        s = socket.create_connection((host, port), timeout=5)
        break
    except OSError:
        time.sleep(1)
if s is None:
    sys.exit("could not connect to cpiod at %s:%d" % (host, port))

def field(n, l=8):
    return ("%.*x" % (l, n)).encode()

def header(name, mode, size):
    nb = name.encode()
    return (b"070701" + field(0) + field(mode) + field(0) + field(0)
            + field(0) + field(0) + field(size) + field(0) + field(0)
            + field(0) + field(0) + field(len(nb)+1) + field(0) + nb + b"\0")

def send(data):
    s.sendall(data)
    pad = len(data) % 4
    if pad:
        s.sendall(b"\0" * (4 - pad))

count = 0
# dirs first (walk top-down), then files
for root, dirs, files in os.walk(src):
    rel = os.path.relpath(root, src)
    guest_dir = "/" if rel == "." else "/" + rel
    st = os.stat(root)
    if guest_dir != "/":
        send(header(guest_dir, (st.st_mode & 0o777) | stat.S_IFDIR, 0))
        count += 1
    for f in files:
        hp = os.path.join(root, f)
        gp = ("/" + f) if rel == "." else ("/" + rel + "/" + f)
        if os.path.islink(hp):
            link = os.readlink(hp)
            send(header(gp, (os.lstat(hp).st_mode & 0o777) | stat.S_IFLNK, len(link)))
            send(link.encode())
        else:
            sz = os.path.getsize(hp)
            send(header(gp, (os.stat(hp).st_mode & 0o777) | stat.S_IFREG, sz))
            with open(hp, "rb") as fh:
                send(fh.read())
        count += 1

send(header("TRAILER!!!", 0, 0))
s.shutdown(socket.SHUT_WR)
try:
    s.recv(1)  # wait for cpiod sync ack
except OSError:
    pass
s.close()
print("pushed %d entries from %s" % (count, src))
