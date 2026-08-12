/*
 * ec2-audit: defensive portability audit for OSv on AWS EC2/Nitro.
 *
 * Probes every hardware/OS feature OSv should expose (CPU, memory, block
 * devices, networking, clock, hugepages, io_uring, IMDS) across Intel, AMD
 * and arm64, then serves the findings as JSON over HTTP. Every probe is
 * written to be skeptical: it cross-checks independent sources, bounds all
 * I/O, and reports "unknown"/"degraded"/"fail" rather than assuming success.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <time.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>

#if defined(__x86_64__)
#include <cpuid.h>
#endif

/* ---- growable string buffer for JSON assembly -------------------------- */

struct buf {
	char *p;
	size_t len;
	size_t cap;
};

static void buf_reserve(struct buf *b, size_t extra)
{
	if (b->len + extra + 1 <= b->cap)
		return;
	size_t ncap = b->cap ? b->cap * 2 : 4096;
	while (ncap < b->len + extra + 1)
		ncap *= 2;
	char *np = realloc(b->p, ncap);
	if (!np) {
		/* Out of memory is fatal for the response; bail loudly. */
		perror("realloc");
		exit(1);
	}
	b->p = np;
	b->cap = ncap;
}

static void buf_add(struct buf *b, const char *s, size_t n)
{
	buf_reserve(b, n);
	memcpy(b->p + b->len, s, n);
	b->len += n;
	b->p[b->len] = '\0';
}

/* Append a string literal without hand-counting its length. */
#define buf_lit(b, s) buf_add((b), (s), sizeof(s) - 1)

static void buf_printf(struct buf *b, const char *fmt, ...)
{
	char tmp[1024];
	va_list ap;
	va_start(ap, fmt);
	int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
	va_end(ap);
	if (n < 0)
		return;
	if ((size_t)n < sizeof(tmp)) {
		buf_add(b, tmp, (size_t)n);
		return;
	}
	buf_reserve(b, (size_t)n);
	va_start(ap, fmt);
	vsnprintf(b->p + b->len, (size_t)n + 1, fmt, ap);
	va_end(ap);
	b->len += (size_t)n;
}

/* Append a JSON string value with proper escaping of the raw input. */
static void buf_json_str(struct buf *b, const char *s)
{
	buf_lit(b, "\"");
	for (const unsigned char *c = (const unsigned char *)s; *c; c++) {
		switch (*c) {
		case '"':  buf_lit(b, "\\\""); break;
		case '\\': buf_lit(b, "\\\\"); break;
		case '\n': buf_lit(b, "\\n"); break;
		case '\r': buf_lit(b, "\\r"); break;
		case '\t': buf_lit(b, "\\t"); break;
		default:
			if (*c < 0x20)
				buf_printf(b, "\\u%04x", *c);
			else
				buf_add(b, (const char *)c, 1);
		}
	}
	buf_lit(b, "\"");
}

/* ---- small helpers ----------------------------------------------------- */

/* Read up to cap-1 bytes of a file into dst; returns bytes read or -1. */
static ssize_t slurp(const char *path, char *dst, size_t cap)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return -1;
	size_t off = 0;
	while (off < cap - 1) {
		ssize_t n = read(fd, dst + off, cap - 1 - off);
		if (n < 0) {
			close(fd);
			return -1;
		}
		if (n == 0)
			break;
		off += (size_t)n;
	}
	dst[off] = '\0';
	close(fd);
	return (ssize_t)off;
}

/* Extract the value after "key" up to newline from a /proc-style text blob. */
static int find_line(const char *blob, const char *key, char *out, size_t cap)
{
	const char *p = strstr(blob, key);
	if (!p)
		return -1;
	p += strlen(key);
	while (*p == ' ' || *p == '\t' || *p == ':')
		p++;
	size_t i = 0;
	while (*p && *p != '\n' && i < cap - 1)
		out[i++] = *p++;
	out[i] = '\0';
	return 0;
}

/* ---- CPU probe --------------------------------------------------------- */

static void probe_cpu(struct buf *b)
{
	buf_lit(b, "\"cpu\":{");

	struct utsname un;
	const char *arch = "unknown";
	if (uname(&un) == 0)
		arch = un.machine;
	buf_lit(b, "\"arch\":");
	buf_json_str(b, arch);

	long onln = sysconf(_SC_NPROCESSORS_ONLN);
	long conf = sysconf(_SC_NPROCESSORS_CONF);
	buf_printf(b, ",\"nproc_online\":%ld,\"nproc_conf\":%ld", onln, conf);

	char vendor[64] = "unknown";
	char features[256] = "";
#if defined(__x86_64__)
	unsigned int a, c[4] = {0, 0, 0, 0};
	unsigned int ebx = 0, ecx = 0, edx = 0;
	if (__get_cpuid(0, &a, &ebx, &ecx, &edx)) {
		memcpy(vendor, &ebx, 4);
		memcpy(vendor + 4, &edx, 4);
		memcpy(vendor + 8, &ecx, 4);
		vendor[12] = '\0';
	}
	unsigned int hv = 0, kvm = 0;
	if (__get_cpuid(1, &a, &c[0], &c[1], &c[3]))
		hv = (c[2] >> 31) & 1;
	if (hv)
		__get_cpuid(0x40000001, &kvm, &c[0], &c[1], &c[3]);
	buf_lit(b, ",\"vendor\":");
	buf_json_str(b, vendor);
	buf_printf(b, ",\"hypervisor_present\":%s", hv ? "true" : "false");
	buf_printf(b, ",\"kvmclock_bits\":%u", hv ? kvm : 0);
#else
	char cpuinfo[8192];
	if (slurp("/proc/cpuinfo", cpuinfo, sizeof(cpuinfo)) > 0) {
		find_line(cpuinfo, "CPU implementer", vendor, sizeof(vendor));
		find_line(cpuinfo, "Features", features, sizeof(features));
	}
	buf_lit(b, ",\"vendor\":");
	buf_json_str(b, vendor);
	buf_lit(b, ",\"features\":");
	buf_json_str(b, features);
#endif
	(void)features;

	const char *status = (onln > 0 && conf > 0 && onln <= conf) ? "ok"
			      : "degraded";
	buf_lit(b, ",\"status\":");
	buf_json_str(b, status);
	buf_lit(b, "}");
}

/* ---- memory probe ------------------------------------------------------ */

static void probe_memory(struct buf *b)
{
	buf_lit(b, "\"memory\":{");

	long pages = sysconf(_SC_PHYS_PAGES);
	long psize = sysconf(_SC_PAGESIZE);
	long long sc_bytes = (long long)pages * (long long)psize;
	buf_printf(b, "\"sysconf_bytes\":%lld,\"page_size\":%ld", sc_bytes, psize);

	char meminfo[4096];
	long long mi_kb = -1;
	if (slurp("/proc/meminfo", meminfo, sizeof(meminfo)) > 0) {
		char val[64];
		if (find_line(meminfo, "MemTotal", val, sizeof(val)) == 0)
			mi_kb = atoll(val);
	}
	buf_printf(b, ",\"meminfo_total_kb\":%lld", mi_kb);

	/* Skeptical cross-check: the two sources should agree within 25%. */
	const char *status = "unknown";
	if (sc_bytes > 0 && mi_kb > 0) {
		long long mi_bytes = mi_kb * 1024;
		long long diff = sc_bytes > mi_bytes ? sc_bytes - mi_bytes
						     : mi_bytes - sc_bytes;
		status = (diff * 4 <= sc_bytes) ? "ok" : "degraded";
	} else if (sc_bytes > 0) {
		status = "degraded";
	}
	buf_lit(b, ",\"status\":");
	buf_json_str(b, status);
	buf_lit(b, "}");
}

/* ---- clock probe ------------------------------------------------------- */

static void probe_clock(struct buf *b)
{
	buf_lit(b, "\"clock\":{");

	struct timespec m0, m1, r0;
	int ok_mono = clock_gettime(CLOCK_MONOTONIC, &m0) == 0;
	int ok_real = clock_gettime(CLOCK_REALTIME, &r0) == 0;

	struct timespec sleep_req = {0, 50 * 1000 * 1000};
	nanosleep(&sleep_req, NULL);
	clock_gettime(CLOCK_MONOTONIC, &m1);

	long long elapsed_ns = (long long)(m1.tv_sec - m0.tv_sec) * 1000000000LL
			       + (m1.tv_nsec - m0.tv_nsec);
	buf_printf(b, "\"mono_ok\":%s,\"real_ok\":%s",
		   ok_mono ? "true" : "false", ok_real ? "true" : "false");
	buf_printf(b, ",\"realtime_epoch\":%lld", (long long)r0.tv_sec);
	buf_printf(b, ",\"sleep50ms_elapsed_ns\":%lld", elapsed_ns);

	/* A working clock advances by roughly the requested 50ms. A broken
	 * TCG/no-kvmclock guest shows ~0 or wildly inflated elapsed time. */
	const char *status = "fail";
	if (ok_mono && elapsed_ns >= 40000000LL && elapsed_ns <= 500000000LL)
		status = "ok";
	else if (ok_mono)
		status = "degraded";
	buf_lit(b, ",\"status\":");
	buf_json_str(b, status);
	buf_lit(b, "}");
}

/* ---- hugepage probe ---------------------------------------------------- */

static void probe_hugepages(struct buf *b)
{
	buf_lit(b, "\"hugepages\":{");

	size_t len = 2 * 1024 * 1024;
	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE,
		       MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);
	int ok = p != MAP_FAILED;
	int wrote = 0;
	if (ok) {
		/* Touch first and last byte to prove the mapping is backed. */
		((volatile char *)p)[0] = 0x5a;
		((volatile char *)p)[len - 1] = 0xa5;
		wrote = ((volatile char *)p)[0] == 0x5a
			&& ((volatile char *)p)[len - 1] == (char)0xa5;
		munmap(p, len);
	} else {
		buf_lit(b, "\"errno\":");
		buf_json_str(b, strerror(errno));
		buf_lit(b, ",");
	}
	buf_printf(b, "\"map_hugetlb\":%s,\"readback_ok\":%s",
		   ok ? "true" : "false", wrote ? "true" : "false");
	const char *status = (ok && wrote) ? "ok" : "fail";
	buf_lit(b, ",\"status\":");
	buf_json_str(b, status);
	buf_lit(b, "}");
}

/* ---- network probe ----------------------------------------------------- */

static void probe_net(struct buf *b)
{
	buf_lit(b, "\"net\":{\"interfaces\":[");

	struct ifaddrs *ifa = NULL;
	int n = 0, routable = 0;
	if (getifaddrs(&ifa) == 0) {
		for (struct ifaddrs *i = ifa; i; i = i->ifa_next) {
			if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET)
				continue;
			struct sockaddr_in *sin =
				(struct sockaddr_in *)i->ifa_addr;
			char ip[INET_ADDRSTRLEN] = "";
			inet_ntop(AF_INET, &sin->sin_addr, ip, sizeof(ip));
			if (n++)
				buf_lit(b, ",");
			buf_lit(b, "{\"name\":");
			buf_json_str(b, i->ifa_name ? i->ifa_name : "?");
			buf_lit(b, ",\"ip\":");
			buf_json_str(b, ip);
			int up = (i->ifa_flags & IFF_UP) != 0;
			int lo = (i->ifa_flags & IFF_LOOPBACK) != 0;
			buf_printf(b, ",\"up\":%s,\"loopback\":%s}",
				   up ? "true" : "false",
				   lo ? "true" : "false");
			if (up && !lo && strcmp(ip, "0.0.0.0") != 0)
				routable++;
		}
		freeifaddrs(ifa);
	}
	buf_printf(b, "],\"count\":%d,\"routable_ipv4\":%d", n, routable);
	const char *status = routable > 0 ? "ok"
			     : (n > 0 ? "degraded" : "fail");
	buf_lit(b, ",\"status\":");
	buf_json_str(b, status);
	buf_lit(b, "}");
}

/* ---- block-device probe ------------------------------------------------ */

/* Try a bounded read of the first sector to prove the device is live. */
static int probe_read_sector(const char *path)
{
	int fd = open(path, O_RDONLY);
	if (fd < 0)
		return 0;
	char sect[512];
	ssize_t r = pread(fd, sect, sizeof(sect), 0);
	close(fd);
	return r == (ssize_t)sizeof(sect);
}

static void probe_block(struct buf *b)
{
	buf_lit(b, "\"block\":{\"devices\":[");

	DIR *d = opendir("/dev");
	int n = 0, readable = 0;
	if (d) {
		struct dirent *de;
		while ((de = readdir(d)) != NULL) {
			if (strncmp(de->d_name, "vblk", 4) != 0)
				continue;
			char path[300];
			snprintf(path, sizeof(path), "/dev/%s", de->d_name);
			int rd = probe_read_sector(path);
			if (n++)
				buf_lit(b, ",");
			buf_lit(b, "{\"name\":");
			buf_json_str(b, de->d_name);
			buf_printf(b, ",\"sector0_read\":%s}",
				   rd ? "true" : "false");
			if (rd)
				readable++;
		}
		closedir(d);
	}
	buf_printf(b, "],\"count\":%d,\"readable\":%d", n, readable);
	const char *status = readable > 0 ? "ok"
			     : (n > 0 ? "degraded" : "fail");
	buf_lit(b, ",\"status\":");
	buf_json_str(b, status);
	buf_lit(b, "}");
}

/* ---- io_uring probe ---------------------------------------------------- */

#ifndef __NR_io_uring_setup
#if defined(__x86_64__)
#define __NR_io_uring_setup 425
#define __NR_io_uring_register 427
#elif defined(__aarch64__)
#define __NR_io_uring_setup 425
#define __NR_io_uring_register 427
#endif
#endif

/* Minimal stable-ABI slice of struct io_uring_params (we read .features). */
struct au_io_uring_params {
	uint32_t sq_entries;
	uint32_t cq_entries;
	uint32_t flags;
	uint32_t sq_thread_cpu;
	uint32_t sq_thread_idle;
	uint32_t features;
	uint32_t wq_fd;
	uint32_t resv[3];
	uint8_t tail[128]; /* room for sq_off + cq_off structs */
};

struct au_probe_op {
	uint8_t op;
	uint8_t resv;
	uint16_t flags;
	uint32_t resv2;
};

struct au_probe {
	uint8_t last_op;
	uint8_t ops_len;
	uint16_t resv;
	uint32_t resv2[3];
	struct au_probe_op ops[256];
};

#define AU_IORING_REGISTER_PROBE 8
#define AU_IO_URING_OP_SUPPORTED 1

static void probe_iouring(struct buf *b)
{
	buf_lit(b, "\"io_uring\":{");
#ifdef __NR_io_uring_setup
	struct au_io_uring_params params;
	memset(&params, 0, sizeof(params));
	long fd = syscall(__NR_io_uring_setup, 8, &params);
	if (fd < 0) {
		buf_lit(b, "\"setup_errno\":");
		buf_json_str(b, strerror(errno));
		buf_lit(b, ",\"status\":\"fail\"}");
		return;
	}
	buf_printf(b, "\"setup_ok\":true,\"features\":%u", params.features);

	struct au_probe pr;
	memset(&pr, 0, sizeof(pr));
	long rc = syscall(__NR_io_uring_register, fd,
			  AU_IORING_REGISTER_PROBE, &pr, 256);
	if (rc == 0) {
		int supported = 0;
		buf_lit(b, ",\"supported_ops\":[");
		for (int i = 0; i < pr.ops_len && i < 256; i++) {
			if (!(pr.ops[i].flags & AU_IO_URING_OP_SUPPORTED))
				continue;
			if (supported++)
				buf_lit(b, ",");
			buf_printf(b, "%u", pr.ops[i].op);
		}
		buf_printf(b, "],\"supported_count\":%d,\"last_op\":%u",
			   supported, pr.last_op);
	} else {
		buf_lit(b, ",\"probe_errno\":");
		buf_json_str(b, strerror(errno));
	}
	close(fd);
	buf_lit(b, ",\"status\":\"ok\"}");
#else
	buf_lit(b, "\"status\":\"unknown\",\"note\":\"no syscall nr\"}");
#endif
}

/* ---- IMDSv2 probe ------------------------------------------------------ */

static int imds_connect(void)
{
	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0)
		return -1;
	struct timeval tv = {2, 0};
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons(80);
	inet_pton(AF_INET, "169.254.169.254", &sa.sin_addr);

	/* SO_SNDTIMEO does not bound connect(); an unreachable IMDS endpoint
	 * would otherwise stall for the full kernel TCP timeout. Drive a
	 * non-blocking connect with a 2s select() ceiling instead. */
	int fl = fcntl(s, F_GETFL, 0);
	fcntl(s, F_SETFL, fl | O_NONBLOCK);
	int rc = connect(s, (struct sockaddr *)&sa, sizeof(sa));
	if (rc != 0 && errno != EINPROGRESS) {
		close(s);
		return -1;
	}
	if (rc != 0) {
		fd_set wf;
		FD_ZERO(&wf);
		FD_SET(s, &wf);
		struct timeval to = {2, 0};
		if (select(s + 1, NULL, &wf, NULL, &to) <= 0) {
			close(s);
			return -1;
		}
		int err = 0;
		socklen_t elen = sizeof(err);
		if (getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &elen) != 0
		    || err != 0) {
			close(s);
			return -1;
		}
	}
	fcntl(s, F_SETFL, fl);
	return s;
}

/* Fetch an IMDSv2 token; returns 1 and fills tok on HTTP 200. */
static int imds_get_token(char *tok, size_t cap)
{
	int s = imds_connect();
	if (s < 0)
		return 0;
	const char *req =
		"PUT /latest/api/token HTTP/1.1\r\n"
		"Host: 169.254.169.254\r\n"
		"X-aws-ec2-metadata-token-ttl-seconds: 60\r\n"
		"Connection: close\r\n\r\n";
	if (write(s, req, strlen(req)) < 0) {
		close(s);
		return 0;
	}
	char resp[2048];
	ssize_t n = read(s, resp, sizeof(resp) - 1);
	close(s);
	if (n <= 0)
		return 0;
	resp[n] = '\0';
	if (strncmp(resp, "HTTP/1.1 200", 12) != 0)
		return 0;
	char *body = strstr(resp, "\r\n\r\n");
	if (!body)
		return 0;
	body += 4;
	size_t i = 0;
	while (body[i] && body[i] != '\r' && body[i] != '\n' && i < cap - 1) {
		tok[i] = body[i];
		i++;
	}
	tok[i] = '\0';
	return i > 0;
}

static void probe_imds(struct buf *b)
{
	buf_lit(b, "\"imds\":{");
	char tok[512] = "";
	int got = imds_get_token(tok, sizeof(tok));
	buf_printf(b, "\"reachable\":%s,\"token_ok\":%s",
		   got ? "true" : "false", got ? "true" : "false");
	const char *status = got ? "ok" : "fail";
	buf_lit(b, ",\"status\":");
	buf_json_str(b, status);
	buf_lit(b, "}");
}

/* ---- report assembly --------------------------------------------------- */

static void build_report(struct buf *b)
{
	buf_lit(b, "{");
	probe_cpu(b);
	buf_lit(b, ",");
	probe_memory(b);
	buf_lit(b, ",");
	probe_clock(b);
	buf_lit(b, ",");
	probe_hugepages(b);
	buf_lit(b, ",");
	probe_net(b);
	buf_lit(b, ",");
	probe_block(b);
	buf_lit(b, ",");
	probe_iouring(b);
	buf_lit(b, ",");
	probe_imds(b);
	buf_lit(b, "}");
}

/* ---- HTTP server ------------------------------------------------------- */

static void dispatch(const char *path, struct buf *out)
{
	if (strcmp(path, "/") == 0 || strcmp(path, "/all") == 0) {
		build_report(out);
		return;
	}
	buf_lit(out, "{");
	if (strcmp(path, "/cpu") == 0) probe_cpu(out);
	else if (strcmp(path, "/memory") == 0) probe_memory(out);
	else if (strcmp(path, "/clock") == 0) probe_clock(out);
	else if (strcmp(path, "/hugepages") == 0) probe_hugepages(out);
	else if (strcmp(path, "/net") == 0) probe_net(out);
	else if (strcmp(path, "/block") == 0) probe_block(out);
	else if (strcmp(path, "/io_uring") == 0) probe_iouring(out);
	else if (strcmp(path, "/imds") == 0) probe_imds(out);
	else buf_lit(out, "\"error\":\"not found\"");
	buf_lit(out, "}");
}

static void handle_conn(int c)
{
	char req[2048];
	ssize_t n = read(c, req, sizeof(req) - 1);
	if (n <= 0)
		return;
	req[n] = '\0';

	char path[512] = "/";
	if (strncmp(req, "GET ", 4) == 0) {
		const char *start = req + 4;
		const char *end = strchr(start, ' ');
		size_t len = end ? (size_t)(end - start) : 0;
		if (len > 0 && len < sizeof(path)) {
			memcpy(path, start, len);
			path[len] = '\0';
		}
	}

	struct buf out = {0};
	dispatch(path, &out);

	struct buf hdr = {0};
	buf_printf(&hdr,
		   "HTTP/1.1 200 OK\r\n"
		   "Content-Type: application/json\r\n"
		   "Content-Length: %zu\r\n"
		   "Connection: close\r\n\r\n",
		   out.len);
	if (write(c, hdr.p, hdr.len) > 0)
		(void)!write(c, out.p, out.len);
	free(hdr.p);
	free(out.p);
}

static int serve(int port)
{
	int s = socket(AF_INET, SOCK_STREAM, 0);
	if (s < 0) {
		perror("socket");
		return 1;
	}
	int one = 1;
	setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_addr.s_addr = htonl(INADDR_ANY);
	sa.sin_port = htons(port);
	if (bind(s, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
		perror("bind");
		return 1;
	}
	if (listen(s, 16) != 0) {
		perror("listen");
		return 1;
	}
	fprintf(stderr, "ec2-audit: listening on :%d\n", port);
	for (;;) {
		int c = accept(s, NULL, NULL);
		if (c < 0) {
			if (errno == EINTR)
				continue;
			perror("accept");
			break;
		}
		handle_conn(c);
		close(c);
	}
	close(s);
	return 0;
}

int main(int argc, char **argv)
{
	int port = 8080;
	int once = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--once") == 0)
			once = 1;
		else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
			port = atoi(argv[++i]);
	}

	if (once) {
		/* Print the full report to stdout and exit (console mode). */
		struct buf out = {0};
		build_report(&out);
		printf("%s\n", out.p);
		fflush(stdout);
		free(out.p);
		return 0;
	}
	return serve(port);
}
