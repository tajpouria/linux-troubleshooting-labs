#!/usr/bin/env bash
#
# storefront-out-of-sync setup: builds the HEALTHY baseline for web-05. Defects come later (break.sh).
#
#   host --http:80--> nginx --proxy--> storefront app (python3, 127.0.0.1:8080, user "storefront")
#                                        |-- stock levels:      reads /var/lib/larch/stock.dat
#                                        |-- delivery estimates: runs `larch quote <book>`, caches 5 min
#                                        '-- orders:             drops a file into /var/spool/larch/outgoing
#
#   larch: Larch Logistics' fulfilment agent, a closed-source vendor binary (/opt/larch/bin/larch)
#     larch-sync.timer, every 2 min   `larch sync`: fetch the warehouse's signed stock feed -> stock.dat
#     larch-ship.service, always on   `larch ship`: move new orders to the warehouse's file drop
#
#   /srv/warehouse: the warehouse's file drop (inbox for our orders, outbox for its
#     stock feed, acks for its acknowledgements). warehouse-sim.timer plays the
#     warehouse on the other side of it. It's scenery, not part of the incident.
#
#   sam: a platform engineer's login account. Platform engineers may run
#     larch's admin commands as the larch user (/etc/sudoers.d/larch).
#
#  ███  SPOILER WARNING for section 3  ███
#  Section 3 contains the vendor agent's C source. In the VM it's a stripped
#  binary with no source, and the lab is about finding out what it does by
#  watching it (strace, /proc, lsof). Reading the source first is like reading
#  the answers. The program itself has no bugs: the incident is all in its
#  surroundings.
#
# Provisioning fails if the smoke test at the end doesn't pass, so break.sh
# always starts from a known-good system.

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MARKER=/var/lib/lab/provisioned
if [[ -e $MARKER ]]; then
  echo "==> [setup] This lab is already provisioned; not touching it."
  echo "    To reset: vagrant snapshot restore --no-provision broken"
  echo "    or rebuild: vagrant destroy -f, then vagrant up"
  exit 0
fi

log() { printf '==> [setup] %s\n' "$*"; }

LARCH_HOME=/opt/larch
LARCH=$LARCH_HOME/bin/larch
SPOOL=/var/spool/larch
DROP=/srv/warehouse
SIM_STATE=/var/lib/warehouse-sim
APP_DIR=/opt/storefront
ACCOUNT=PINEWOOD-0042
BUILD=$(mktemp -d /run/lab-build.XXXXXX)
trap 'rm -rf "$BUILD"' EXIT

# --- 1. Packages -------------------------------------------------------------
# gcc builds the vendor agent below. manpages-dev has the system call manual
# (man 2 open), and moreutils has `errno` (errno -l lists every error code).
log "Installing nginx, python3, tmux, a C compiler and the system call manual pages"
apt-get -y -qq -o DPkg::Lock::Timeout=600 install \
  nginx python3 tmux gcc libc6-dev binutils file man-db manpages manpages-dev moreutils >/dev/null

# --- 2. Accounts ---------------------------------------------------------------
install -d -m 0755 /var/lib/lab
if ! id larch >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /var/lib/larch --create-home \
    --shell /usr/sbin/nologin --comment "Larch fulfilment agent" larch
fi
chmod 0755 /var/lib/larch
if ! id storefront >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /var/lib/storefront --create-home \
    --shell /usr/sbin/nologin --comment "Pinewood Books storefront" storefront
fi
chmod 0755 /var/lib/storefront
# The storefront drops orders into larch's spool, which belongs to group larch.
usermod -aG larch storefront
if ! id sam >/dev/null 2>&1; then
  # A colleague's login account (password login disabled, like everyone's here).
  useradd --create-home --shell /bin/bash --comment "Sam Ortiz (Platform team)" sam
fi

# --- 3. The vendor agent (SPOILERS: the source of a "closed-source" binary) ------
log "Building the Larch agent"
cat >"$BUILD/larch.c" <<'C'
/*
 * larch 4.2.1: Larch Logistics' fulfilment agent.
 *
 * The lab's stand-in for a closed-source vendor binary. setup.sh compiles it,
 * installs the stripped binary as /opt/larch/bin/larch and deletes this source.
 *
 *   larch sync              fetch the warehouse's stock feed  (larch-sync.timer, user larch)
 *   larch ship              send new orders to the warehouse  (larch-ship.service, user larch)
 *   larch quote <book>      print a delivery estimate         (the storefront runs it)
 *   larch admin reconcile   re-send orders the warehouse never acknowledged
 *   larch version
 *
 * Configuration: the first file that exists of $LARCH_CONF, $HOME/.larch.conf,
 * /usr/local/etc/larch/larch.conf and /etc/larch/larch.conf. After a
 * system-wide file, /etc/larch/conf.d/(*).conf are read too.
 *
 * Error messages are terse on purpose, like many vendors': a code, never the
 * reason (no strerror). The vendor's answer is "send us an strace".
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <locale.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#define VERSION "4.2.1"

struct config {
	char account[64];
	char key_file[PATH_MAX];
	char feed[PATH_MAX];
	char stock_file[PATH_MAX];
	char spool[PATH_MAX];
	char inbox[PATH_MAX];
	char acks[PATH_MAX];
	char rates_socket[sizeof(((struct sockaddr_un *)0)->sun_path)];
	int poll_seconds;
};

static struct config cfg;
static const char *who = "larch";

static void say(const char *fmt, ...)
{
	char msg[1024];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(msg, sizeof msg, fmt, ap);
	va_end(ap);
	fprintf(stderr, "larch[%s]: %s\n", who, msg);
}

#define die(...) do { say(__VA_ARGS__); exit(1); } while (0)

static void copy(char *dst, size_t size, const char *src)
{
	snprintf(dst, size, "%s", src);
}
#define COPY(field, value) copy(field, sizeof field, value)

static char *trim(char *s)
{
	char *end;

	while (*s == ' ' || *s == '\t')
		s++;
	end = s + strlen(s);
	while (end > s && strchr(" \t\r\n", end[-1]))
		*--end = '\0';
	return s;
}

/* Read a whole (small) file into memory. NULL if it can't be read. */
static char *slurp(const char *path, size_t *len)
{
	size_t cap = 4096, n = 0;
	ssize_t r;
	char *buf;
	int fd = open(path, O_RDONLY | O_CLOEXEC);

	if (fd < 0)
		return NULL;
	if (!(buf = malloc(cap)))
		exit(1);
	for (;;) {
		if (n + 1 >= cap && !(buf = realloc(buf, cap *= 2)))
			exit(1);
		r = read(fd, buf + n, cap - n - 1);
		if (r < 0 && errno == EINTR)
			continue;
		if (r < 0) {
			free(buf);
			close(fd);
			return NULL;
		}
		if (r == 0)
			break;
		n += r;
	}
	close(fd);
	buf[n] = '\0';
	if (len)
		*len = n;
	return buf;
}

/* --- configuration ------------------------------------------------------- */

static void parse_config(int fd)
{
	char line[1024], *key, *value, *eq, *hash;
	FILE *fh = fdopen(fd, "r");

	if (!fh)
		die("E1002 cannot read the configuration");
	while (fgets(line, sizeof line, fh)) {
		if ((hash = strchr(line, '#')))
			*hash = '\0';
		if (!(eq = strchr(line, '=')))
			continue;
		*eq = '\0';
		key = trim(line);
		value = trim(eq + 1);
		if (!strcmp(key, "account"))
			COPY(cfg.account, value);
		else if (!strcmp(key, "key_file"))
			COPY(cfg.key_file, value);
		else if (!strcmp(key, "feed"))
			COPY(cfg.feed, value);
		else if (!strcmp(key, "stock_file"))
			COPY(cfg.stock_file, value);
		else if (!strcmp(key, "spool"))
			COPY(cfg.spool, value);
		else if (!strcmp(key, "inbox"))
			COPY(cfg.inbox, value);
		else if (!strcmp(key, "acks"))
			COPY(cfg.acks, value);
		else if (!strcmp(key, "rates_socket"))
			COPY(cfg.rates_socket, value);
		else if (!strcmp(key, "poll_seconds"))
			cfg.poll_seconds = atoi(value) > 0 ? atoi(value) : 2;
	}
	fclose(fh);
}

static int conf_filter(const struct dirent *d)
{
	size_t n = strlen(d->d_name);

	return d->d_name[0] != '.' && n > 5 && !strcmp(d->d_name + n - 5, ".conf");
}

static void load_dropins(void)
{
	struct dirent **names;
	char path[PATH_MAX];
	int n = scandir("/etc/larch/conf.d", &names, conf_filter, alphasort), fd;

	for (int i = 0; i < n; i++) {
		snprintf(path, sizeof path, "/etc/larch/conf.d/%s", names[i]->d_name);
		if ((fd = open(path, O_RDONLY | O_CLOEXEC)) >= 0)
			parse_config(fd);
		free(names[i]);
	}
	if (n >= 0)
		free(names);
}

static void load_config(void)
{
	static const char *system_files[] = {"/usr/local/etc/larch/larch.conf", "/etc/larch/larch.conf"};
	const char *env = getenv("LARCH_CONF"), *home = getenv("HOME");
	char path[PATH_MAX];
	int fd;

	COPY(cfg.key_file, "/etc/larch/keys/warehouse.key");
	COPY(cfg.feed, "/srv/warehouse/outbox/stock.csv");
	COPY(cfg.stock_file, "/var/lib/larch/stock.dat");
	COPY(cfg.spool, "/var/spool/larch");
	COPY(cfg.inbox, "/srv/warehouse/inbox");
	COPY(cfg.acks, "/srv/warehouse/acks");
	cfg.poll_seconds = 2;

	if (env && *env) {
		if ((fd = open(env, O_RDONLY | O_CLOEXEC)) < 0)
			die("E1001 no configuration found");
		parse_config(fd);
		return;
	}
	if (home && *home) {
		snprintf(path, sizeof path, "%s/.larch.conf", home);
		if ((fd = open(path, O_RDONLY | O_CLOEXEC)) >= 0) {
			parse_config(fd);
			return;
		}
	}
	for (size_t i = 0; i < sizeof system_files / sizeof *system_files; i++) {
		if ((fd = open(system_files[i], O_RDONLY | O_CLOEXEC)) >= 0) {
			parse_config(fd);
			load_dropins();
			return;
		}
	}
	die("E1001 no configuration found");
}

/* --- credentials and the stock feed ---------------------------------------- */

static void load_key(char *secret, size_t size)
{
	char account[64] = "", *text = slurp(cfg.key_file, NULL), *line, *save;

	secret[0] = '\0';
	if (!text)
		die("E2041 credential check failed");
	for (line = strtok_r(text, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
		line = trim(line);
		if (!strncmp(line, "account=", 8))
			COPY(account, line + 8);
		else if (!strncmp(line, "secret=", 7))
			copy(secret, size, line + 7);
	}
	free(text);
	if (!*secret || strcmp(account, cfg.account))
		die("E2041 credential check failed");
}

static uint64_t fnv1a(uint64_t h, const char *p, size_t n)
{
	while (n--) {
		h ^= (unsigned char)*p++;
		h *= 0x100000001b3ULL;
	}
	return h;
}

/* The feed's signature: FNV-1a 64 over "<secret>\n<body>". (A real vendor would use HMAC.) */
static void feed_mac(const char *secret, const char *body, size_t n, char *out, size_t size)
{
	uint64_t h = fnv1a(0xcbf29ce484222325ULL, secret, strlen(secret));

	h = fnv1a(fnv1a(h, "\n", 1), body, n);
	snprintf(out, size, "%016llx", (unsigned long long)h);
}

static int header_field(const char *header, const char *name, char *out, size_t size)
{
	size_t n = strlen(name), len;
	const char *p = header;

	while ((p = strstr(p, name))) {
		if ((p == header || p[-1] == ' ') && p[n] == '=') {
			p += n + 1;
			len = strcspn(p, " ");
			if (len >= size)
				len = size - 1;
			memcpy(out, p, len);
			out[len] = '\0';
			return 1;
		}
		p += n;
	}
	return 0;
}

static int cmd_sync(void)
{
	char secret[256], account[64], generated[64], mac[32], expected[32], tmp[PATH_MAX + 8];
	char *feed, *body, *nl, *line, *save;
	int fd, titles = 0, id, qty, lead;
	size_t len;
	FILE *out;

	who = "sync";
	load_config();
	load_key(secret, sizeof secret);
	if (!(feed = slurp(cfg.feed, &len)))
		die("E2042 warehouse feed unavailable");
	if (!(nl = strchr(feed, '\n')))
		die("E2043 warehouse feed rejected");
	*nl = '\0';
	body = nl + 1;
	if (strncmp(feed, "# larch-feed 2 ", 15) || !header_field(feed, "account", account, sizeof account) ||
	    !header_field(feed, "generated", generated, sizeof generated) ||
	    !header_field(feed, "mac", mac, sizeof mac))
		die("E2043 warehouse feed rejected");
	feed_mac(secret, body, len - (size_t)(body - feed), expected, sizeof expected);
	if (strcmp(account, cfg.account) || strcmp(mac, expected))
		die("E2043 warehouse feed rejected");

	snprintf(tmp, sizeof tmp, "%s.tmp", cfg.stock_file);
	if ((fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644)) < 0 || !(out = fdopen(fd, "w")))
		die("E2044 cannot store stock levels");
	fprintf(out, "# larch stock 2 generated=%s synced=%lld\n", generated, (long long)time(NULL));
	for (line = strtok_r(body, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
		if (sscanf(line, "%d,%d,%d", &id, &qty, &lead) == 3) {
			fprintf(out, "%d %d %d\n", id, qty, lead);
			titles++;
		}
	}
	if (fflush(out) || fsync(fd) || fclose(out) || rename(tmp, cfg.stock_file))
		die("E2044 cannot store stock levels");
	say("synced %d titles (feed generated %s)", titles, generated);
	free(feed);
	return 0;
}

/* --- delivery estimates ------------------------------------------------------ */

static int lookup_stock(int book, int *qty, int *lead)
{
	char *text = slurp(cfg.stock_file, NULL), *line, *save;
	int id, q, l, found = 0;

	if (!text)
		return 0;
	for (line = strtok_r(text, "\n", &save); line && !found; line = strtok_r(NULL, "\n", &save)) {
		if (line[0] != '#' && sscanf(line, "%d %d %d", &id, &q, &l) == 3 && id == book) {
			*qty = q;
			*lead = l;
			found = 1;
		}
	}
	free(text);
	return found;
}

static int cmd_quote(const char *arg)
{
	static const int backoff_ms[] = {500, 1000, 2000};
	int book = atoi(arg), qty = 0, lead = 0, known, fd;

	who = "quote";
	load_config();
	known = lookup_stock(book, &qty, &lead);

	if (cfg.rates_socket[0]) {
		/* Live shipping rates from Larch's rate service, with a few retries. */
		struct sockaddr_un addr = {.sun_family = AF_UNIX};
		char reply[256];
		ssize_t n;

		copy(addr.sun_path, sizeof addr.sun_path, cfg.rates_socket);
		for (int attempt = 0;; attempt++) {
			fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
			if (fd >= 0 && connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0) {
				dprintf(fd, "RATE %d %d\n", book, known ? qty : -1);
				n = read(fd, reply, sizeof reply - 1);
				close(fd);
				if (n > 0) {
					reply[n] = '\0';
					puts(trim(reply));
					return 0;
				}
				break;
			}
			if (fd >= 0)
				close(fd);
			if (attempt == 3)
				break;
			struct timespec delay = {backoff_ms[attempt] / 1000, (backoff_ms[attempt] % 1000) * 1000000L};
			nanosleep(&delay, NULL);
		}
		say("W3101 live rates unavailable, using the default estimate");
		puts("Usually ships in 3-5 working days.");
		return 0;
	}

	if (!known)
		puts("Delivery estimate unavailable.");
	else if (qty > 0 && lead <= 1)
		puts("In stock: ships tomorrow.");
	else if (qty > 0)
		printf("In stock: ships in %d working days.\n", lead);
	else
		printf("Out of stock: ships in about %d working days.\n", lead);
	return 0;
}

/* --- orders -------------------------------------------------------------------- */

static int order_filter(const struct dirent *d)
{
	size_t n = strlen(d->d_name);

	return d->d_name[0] != '.' && n > 6 && !strcmp(d->d_name + n - 6, ".order");
}

static int open_lock(void)
{
	char path[PATH_MAX];
	int fd;

	snprintf(path, sizeof path, "%s/spool.lock", cfg.spool);
	if ((fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0660)) < 0)
		die("E2051 spool unavailable");
	return fd;
}

/* Copy one order into the warehouse's inbox: write a hidden .part file, then rename it. */
static int deliver(const char *src, const char *name)
{
	char part[PATH_MAX], dst[PATH_MAX];
	size_t len;
	char *body = slurp(src, &len);
	int fd, ok;

	if (!body)
		return -1;
	snprintf(part, sizeof part, "%s/.%s.part", cfg.inbox, name);
	snprintf(dst, sizeof dst, "%s/%s", cfg.inbox, name);
	fd = open(part, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0640);
	ok = fd >= 0 && write(fd, body, len) == (ssize_t)len && fsync(fd) == 0;
	if (fd >= 0)
		close(fd);
	free(body);
	if (!ok || rename(part, dst) != 0) {
		unlink(part);
		return -1;
	}
	return 0;
}

static void ship_pending(void)
{
	char outgoing[PATH_MAX], src[PATH_MAX * 2], done[PATH_MAX * 2];
	struct dirent **names;
	int n;

	snprintf(outgoing, sizeof outgoing, "%s/outgoing", cfg.spool);
	if ((n = scandir(outgoing, &names, order_filter, alphasort)) < 0) {
		say("E2052 cannot read the spool");
		return;
	}
	for (int i = 0; i < n; i++) {
		const char *name = names[i]->d_name;

		snprintf(src, sizeof src, "%s/%s", outgoing, name);
		snprintf(done, sizeof done, "%s/sent/%s", cfg.spool, name);
		if (deliver(src, name) != 0) {
			say("E2053 cannot deliver %s", name);
			break;
		}
		if (rename(src, done) != 0) {
			say("E2054 cannot file %s", name);
			break;
		}
		say("sent %.*s", (int)strlen(name) - 6, name);
	}
	for (int i = 0; i < n; i++)
		free(names[i]);
	free(names);
}

static int cmd_ship(void)
{
	int lock;

	who = "ship";
	load_config();
	lock = open_lock();
	say("larch %s: shipping new orders from %s/outgoing every %d s", VERSION, cfg.spool, cfg.poll_seconds);
	for (;;) {
		/* One larch at a time in the spool: ship and admin commands take turns. */
		if (flock(lock, LOCK_EX) != 0)
			die("E2051 spool unavailable");
		ship_pending();
		flock(lock, LOCK_UN);
		sleep(cfg.poll_seconds);
	}
}

static int cmd_reconcile(void)
{
	char sent[PATH_MAX], path[PATH_MAX * 2], answer[16] = "";
	struct dirent **names;
	int lock, n, missing = 0, *idx;

	who = "admin";
	load_config();
	lock = open_lock();
	if (flock(lock, LOCK_EX | LOCK_NB) != 0) {
		printf("Waiting for the spool lock...\n");
		fflush(stdout);
		if (flock(lock, LOCK_EX) != 0)
			die("E2051 spool unavailable");
	}
	printf("larch %s reconcile: comparing shipped orders with the warehouse's acknowledgements...\n",
	       VERSION);
	snprintf(sent, sizeof sent, "%s/sent", cfg.spool);
	if ((n = scandir(sent, &names, order_filter, alphasort)) < 0)
		die("E2052 cannot read the spool");
	if (!(idx = calloc(n ? n : 1, sizeof *idx)))
		exit(1);
	for (int i = 0; i < n; i++) {
		snprintf(path, sizeof path, "%s/%.*s.ack", cfg.acks, (int)strlen(names[i]->d_name) - 6,
			 names[i]->d_name);
		if (access(path, F_OK) != 0)
			idx[missing++] = i;
	}
	printf("%d orders shipped, %d acknowledged.\n", n, n - missing);
	if (missing == 0) {
		printf("Nothing to do.\n");
		return 0;
	}
	printf("\n%d shipped order%s with no acknowledgement from the warehouse:\n", missing,
	       missing == 1 ? "" : "s");
	for (int i = 0; i < missing; i++)
		printf("  %.*s\n", (int)strlen(names[idx[i]]->d_name) - 6, names[idx[i]]->d_name);
	printf("\nRe-send %s to the warehouse now? Orders the warehouse already has will be shipped twice. [y/N] ",
	       missing == 1 ? "it" : "them");
	fflush(stdout);
	if (!fgets(answer, sizeof answer, stdin))
		answer[0] = '\0';
	if (answer[0] == 'y' || answer[0] == 'Y') {
		int resent = 0;

		for (int i = 0; i < missing; i++) {
			snprintf(path, sizeof path, "%s/%s", sent, names[idx[i]]->d_name);
			if (deliver(path, names[idx[i]]->d_name) == 0)
				resent++;
		}
		printf("Re-sent %d order%s.\n", resent, resent == 1 ? "" : "s");
	} else {
		printf("Nothing changed.\n");
	}
	flock(lock, LOCK_UN);
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: larch sync | ship | quote <book> | admin reconcile | version\n"
		"Larch Logistics fulfilment agent %s. See /opt/larch/README.\n", VERSION);
}

int main(int argc, char **argv)
{
	setlocale(LC_ALL, "");
	if (argc >= 2 && !strcmp(argv[1], "sync"))
		return cmd_sync();
	if (argc >= 2 && !strcmp(argv[1], "ship"))
		return cmd_ship();
	if (argc >= 3 && !strcmp(argv[1], "quote"))
		return cmd_quote(argv[2]);
	if (argc >= 3 && !strcmp(argv[1], "admin") && !strcmp(argv[2], "reconcile"))
		return cmd_reconcile();
	if (argc >= 2 && (!strcmp(argv[1], "version") || !strcmp(argv[1], "--version"))) {
		printf("larch %s (Larch Logistics fulfilment agent)\n", VERSION);
		return 0;
	}
	usage();
	return 2;
}
C
install -d -m 0755 "$LARCH_HOME" "$LARCH_HOME/bin"
gcc -O2 -Wall -Wextra -Wno-format-truncation -o "$BUILD/larch" "$BUILD/larch.c"
install -m 0755 -s "$BUILD/larch" "$LARCH"
ln -sf "$LARCH" /usr/local/bin/larch
rm -f "$BUILD/larch.c" "$BUILD/larch"

cat >"$LARCH_HOME/README" <<'EOF'
LARCH FULFILMENT AGENT 4.2
Larch Logistics - "We ship, you sell."

The agent connects your shop to your Larch warehouse.

  larch sync              Fetch the warehouse's stock levels. Run it every few
                          minutes as the larch user (we ship a systemd timer).
  larch ship              Send new orders to the warehouse. Runs all the time,
                          as the larch user (we ship a systemd service).
  larch quote <book>      Print a delivery estimate for one title.
  larch admin reconcile   Compare shipped orders with the warehouse's
                          acknowledgements, and offer to re-send the ones that
                          have none. Run admin commands as the larch user.
  larch version

CONFIGURATION
  /etc/larch/larch.conf. See the comments in that file.

FILES
  /etc/larch/keys/warehouse.key   your warehouse key. Readable by larch only.
  /var/lib/larch/stock.dat        the last stock levels fetched
  /var/spool/larch/outgoing/      orders waiting to be sent, one file each
  /var/spool/larch/sent/          orders sent to the warehouse

MESSAGES
  E1xxx   configuration
  E2041   credential check failed
  E2042   warehouse feed unavailable
  E2043   warehouse feed rejected
  E2044   cannot store stock levels
  E205x   spool or warehouse file drop
  W3101   live rates unavailable, using the default estimate

SUPPORT
  support@larch-logistics.example. We answer within 5 working days.
  To speed up your case, attach an strace of the failing command.
EOF
chmod 0644 "$LARCH_HOME/README"

# --- 4. Configuration and the warehouse key -----------------------------------------
log "Configuring the Larch agent"
install -d -m 0755 /etc/larch
cat >/etc/larch/larch.conf <<EOF
# Larch fulfilment agent 4.2: Pinewood Books (web-05)
account      = $ACCOUNT
key_file     = /etc/larch/keys/warehouse.key

# The warehouse's file drop.
feed         = $DROP/outbox/stock.csv
inbox        = $DROP/inbox
acks         = $DROP/acks

stock_file   = /var/lib/larch/stock.dat
spool        = $SPOOL
poll_seconds = 2

# Live shipping rates come from Larch's optional rate service (larch-rated),
# which we don't run. Without it, quotes use the lead times in the stock feed.
#rates_socket = /run/larch/rates.sock
EOF
chmod 0644 /etc/larch/larch.conf

install -d -o root -g larch -m 0750 /etc/larch/keys
secret=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
printf 'account=%s\nsecret=%s\n' "$ACCOUNT" "$secret" >/etc/larch/keys/warehouse.key
chown root:larch /etc/larch/keys/warehouse.key
chmod 0640 /etc/larch/keys/warehouse.key

# --- 5. Spool, stock levels and the warehouse's file drop ---------------------------
install -d -o larch -g larch -m 0755 /var/lib/larch
install -d -o larch -g larch -m 0750 "$SPOOL"
install -d -o larch -g larch -m 2770 "$SPOOL/outgoing" # the storefront (group larch) drops orders here
install -d -o larch -g larch -m 0750 "$SPOOL/sent"
install -d -m 0755 "$DROP"
install -d -o larch -g larch -m 0750 "$DROP/inbox"
install -d -m 0755 "$DROP/outbox" "$DROP/acks"
install -d -m 0700 "$SIM_STATE" "$SIM_STATE/received"
printf '%s\n' "$secret" >"$SIM_STATE/secret"
chmod 0600 "$SIM_STATE/secret"
unset secret

# The warehouse's shelves: quantity, lead time when in stock, and restock time.
python3 - "$SIM_STATE/stock.json" <<'PY'
import json, sys
shelves = {1: (14, 1, 6), 2: (6, 1, 9), 3: (22, 1, 5), 4: (9, 2, 8), 5: (11, 1, 7), 6: (4, 1, 10),
           7: (17, 1, 6), 8: (8, 2, 12), 9: (5, 1, 8), 10: (12, 1, 6), 11: (7, 2, 9), 12: (19, 1, 5)}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({str(b): {"qty": q, "lead": l, "restock": r} for b, (q, l, r) in shelves.items()}, fh, indent=1)
PY
chmod 0600 "$SIM_STATE/stock.json"

# --- 6. The warehouse simulator (scenery) ---------------------------------------------
cat >/usr/local/sbin/warehouse-sim <<'PY'
#!/usr/bin/env python3
"""warehouse-sim: plays Larch Logistics' warehouse in this lab.

It's scenery, not part of the incident, so leave it alone. warehouse-sim.timer
runs it every minute. Each run:
  * receives the orders that larch-ship dropped into /srv/warehouse/inbox,
    writes an acknowledgement for each one into /srv/warehouse/acks, and takes
    the books off its shelves;
  * publishes its stock levels as a signed feed, /srv/warehouse/outbox/stock.csv,
    for `larch sync` to fetch.
The warehouse's own records live in /var/lib/warehouse-sim.
"""

import json
import os
import sys
import time

DROP = "/srv/warehouse"
STATE = "/var/lib/warehouse-sim"
ACCOUNT = "PINEWOOD-0042"


def mac(secret, body):
    h = 0xCBF29CE484222325
    for byte in secret.encode() + b"\n" + body:
        h = ((h ^ byte) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return f"{h:016x}"


def write(path, text, mode):
    tmp = os.path.join(os.path.dirname(path), f".{os.path.basename(path)}.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def main():
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    with open(f"{STATE}/stock.json", encoding="utf-8") as fh:
        stock = json.load(fh)
    with open(f"{STATE}/secret", encoding="utf-8") as fh:
        secret = fh.read().strip()

    received = 0
    for name in sorted(os.listdir(f"{DROP}/inbox")):
        if name.startswith(".") or not name.endswith(".order"):
            continue
        order_id = name[:-len(".order")]
        src = f"{DROP}/inbox/{name}"
        try:
            with open(src, encoding="utf-8") as fh:
                fields = dict(line.split(" ", 1) for line in fh.read().splitlines() if " " in line)
        except OSError:
            continue
        dst, n = f"{STATE}/received/{name}", 0
        while os.path.exists(dst):  # the warehouse got this order before
            n += 1
            dst = f"{STATE}/received/{order_id}.dup{n}.order"
        os.replace(src, dst)
        write(f"{DROP}/acks/{order_id}.ack", f"received {now}\n", 0o644)
        shelf = stock.get(fields.get("book", "").strip())
        if shelf:
            shelf["qty"] = max(0, shelf["qty"] - int(fields.get("qty", "1")))
        received += 1

    write(f"{STATE}/stock.json", json.dumps(stock, indent=1), 0o600)
    body = "".join(f"{book},{s['qty']},{s['lead'] if s['qty'] > 0 else s['restock']}\n"
                   for book, s in sorted(stock.items(), key=lambda kv: int(kv[0])))
    header = f"# larch-feed 2 account={ACCOUNT} generated={now} mac={mac(secret, body.encode())}\n"
    write(f"{DROP}/outbox/stock.csv", header + body, 0o644)
    print(f"received {received} orders, published stock levels for {len(stock)} titles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 /usr/local/sbin/warehouse-sim
python3 -m py_compile /usr/local/sbin/warehouse-sim
rm -rf /usr/local/sbin/__pycache__

cat >/etc/systemd/system/warehouse-sim.service <<'EOF'
[Unit]
Description=Larch's warehouse (simulated for this lab; not part of the incident)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/warehouse-sim
EOF

cat >/etc/systemd/system/warehouse-sim.timer <<'EOF'
[Unit]
Description=Run the simulated Larch warehouse every minute

[Timer]
OnCalendar=minutely
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

# --- 7. Larch's systemd units (as Larch ships them) -----------------------------------
cat >/etc/systemd/system/larch-sync.service <<EOF
[Unit]
Description=Larch: fetch the warehouse's stock levels
After=network-online.target

[Service]
Type=oneshot
User=larch
Group=larch
ExecStart=$LARCH sync
EOF

cat >/etc/systemd/system/larch-sync.timer <<'EOF'
[Unit]
Description=Larch: fetch the warehouse's stock levels every 2 minutes

[Timer]
OnCalendar=*:0/2
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/larch-ship.service <<EOF
[Unit]
Description=Larch: send new orders to the warehouse
After=network-online.target

[Service]
Type=simple
User=larch
Group=larch
ExecStart=$LARCH ship
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/sudoers.d/larch <<EOF
# Platform engineers run Larch's admin commands as the larch user, as Larch's docs ask.
sam ALL=(larch) NOPASSWD: $LARCH, /usr/local/bin/larch
EOF
chmod 0440 /etc/sudoers.d/larch
visudo -cqf /etc/sudoers.d/larch

# --- 8. Storefront application ---------------------------------------------------------
log "Installing the storefront app"
install -d -m 0755 "$APP_DIR"
cat >"$APP_DIR/app.py" <<'PY'
#!/usr/bin/env python3
"""Pinewood Books storefront (web-05).

Pages: / (every book, and whether it's in stock), /book/<id> (with a delivery
estimate and an order button), POST /order, and /healthz (cheap on purpose: it
only says the process is up).

Where things come from:
  * Stock levels: STOCK_FILE, which the Larch agent keeps up to date
    (larch-sync.timer fetches the warehouse's stock levels every 2 minutes).
  * Delivery estimates: `larch quote <book>`, cached for 5 minutes per book in
    CACHE_DIR.
  * Orders: one file per order, dropped into Larch's spool (OUTGOING).
    larch-ship sends them on to the warehouse.
"""

import argparse
import html
import os
import re
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

LARCH = "/opt/larch/bin/larch"
STOCK_FILE = "/var/lib/larch/stock.dat"
OUTGOING = "/var/spool/larch/outgoing"
CACHE_DIR = "/var/cache/storefront/estimates"
ORDER_SEQ = "/var/lib/storefront/order-seq"
CACHE_SECONDS = 300

BOOKS = {
    1: ("The Quiet Kernel", "Ada Lindqvist", "18.00"),
    2: ("Paging at Midnight", "R. Okafor", "14.50"),
    3: ("A Field Guide to Small Rivers", "Maren Holt", "22.00"),
    4: ("Letters from the Night Shift", "J. Castellano", "16.75"),
    5: ("The Lighthouse Ledger", "Priya Raman", "19.25"),
    6: ("Load Average", "Tomas Brandt", "12.99"),
    7: ("Winter Inventory", "Elif Sahin", "21.50"),
    8: ("The Patient Scheduler", "Noor Haddad", "17.00"),
    9: ("Salt and Signal", "Corin Vale", "15.25"),
    10: ("A Short History of Waiting", "M. Adeyemi", "13.75"),
    11: ("The Housekeeper's Almanac", "Ines Moreau", "20.00"),
    12: ("Every Fifth Minute", "Lars Eklund", "16.00"),
}
BOOK_PATH_RE = re.compile(r"^/book/(\d+)$")
SEQ_LOCK = threading.Lock()


def stock_levels():
    """{book id: quantity} from the Larch agent's last sync."""
    levels = {}
    try:
        with open(STOCK_FILE, encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) == 3 and not line.startswith("#"):
                    levels[int(parts[0])] = int(parts[1])
    except (OSError, ValueError):
        pass
    return levels


def availability(qty):
    if qty is None:
        return "Availability unknown"
    if qty <= 0:
        return "Out of stock"
    if qty <= 3:
        return f"Only {qty} left"
    return "In stock"


def estimate(book_id):
    """A delivery estimate from the Larch agent, cached for CACHE_SECONDS."""
    path = os.path.join(CACHE_DIR, str(book_id))
    try:
        if time.time() - os.stat(path).st_mtime < CACHE_SECONDS:
            with open(path, encoding="utf-8") as fh:
                return fh.read().strip()
    except OSError:
        pass
    try:
        result = subprocess.run([LARCH, "quote", str(book_id)], stdout=subprocess.PIPE, text=True, timeout=20)
        text = result.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        text = ""
    if not text:
        return "Delivery estimate unavailable."
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = f"{path}.{threading.get_ident()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text + "\n")
    os.replace(tmp, path)
    return text


def place_order(book_id):
    """Drop one order into Larch's spool. Returns the order id."""
    with SEQ_LOCK:
        try:
            with open(ORDER_SEQ, encoding="utf-8") as fh:
                seq = int(fh.read().strip() or 0)
        except (OSError, ValueError):
            seq = 0
        seq += 1
        with open(ORDER_SEQ + ".tmp", "w", encoding="utf-8") as fh:
            fh.write(f"{seq}\n")
        os.replace(ORDER_SEQ + ".tmp", ORDER_SEQ)
    order_id = f"PB-{time.strftime('%Y%m%d', time.gmtime())}-{seq:04d}"
    placed = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    tmp = os.path.join(OUTGOING, f".{order_id}.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(f"order {order_id}\nplaced {placed}\nbook {book_id}\nqty 1\n")
    os.replace(tmp, os.path.join(OUTGOING, f"{order_id}.order"))
    print(f"order {order_id}: book {book_id}", flush=True)
    return order_id


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  body {{ font-family: Georgia, serif; max-width: 44rem; margin: 2rem auto; padding: 0 1rem;
         color: #2b2b2b; background: #fbf8f1; }}
  header {{ border-bottom: 2px solid #3c5a40; margin-bottom: 1.5rem; }}
  header a {{ color: inherit; text-decoration: none; }}
  h1 {{ color: #3c5a40; margin: 0 0 .25rem; }}
  .tagline {{ margin: 0 0 1rem; color: #666; }}
  li {{ margin: .5rem 0; }}
  .price {{ color: #3c5a40; font-weight: bold; }}
  .stock {{ font-size: .85rem; color: #555; }}
  .out {{ color: #a33; }}
  button {{ font: inherit; }}
  footer {{ margin-top: 2rem; font-size: .8rem; color: #888; }}
</style>
</head>
<body>
<header>
  <h1><a href="/">Pinewood Books</a></h1>
  <p class="tagline">Independent booksellers since 1987 &middot; shipped by Larch Logistics</p>
</header>
{body}
<footer>Served by {host}</footer>
</body>
</html>
"""


def page(title, body):
    return PAGE.format(title=html.escape(title), body=body, host=html.escape(socket.gethostname()))


class Handler(BaseHTTPRequestHandler):
    server_version = "storefront/5.1"

    def log_message(self, fmt, *args):
        pass  # nginx already logs every request

    def send(self, status, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        try:
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            # The visitor gave up waiting, and nginx closed our connection.
            self.close_connection = True
            print(f"visitor left before the page was ready: {self.command} {self.path}", flush=True)

    def handle_request(self):
        path = self.path.split("?", 1)[0]
        if path == "/healthz":
            return self.send(200, '{"status": "ok"}\n', "application/json")
        if self.command == "POST":
            if path == "/order":
                return self.order()
            return self.send(405, "method not allowed\n", "text/plain; charset=utf-8")
        if path == "/":
            return self.home()
        if m := BOOK_PATH_RE.match(path):
            return self.book(int(m.group(1)))
        return self.send(404, page("Not found", "<p>Sorry, that page doesn't exist.</p>"))

    def home(self):
        levels = stock_levels()
        items = []
        for book_id, (title, author, price) in BOOKS.items():
            qty = levels.get(book_id)
            css = "stock out" if not qty else "stock"
            items.append(f'  <li data-book="{book_id}" data-stock="{"" if qty is None else qty}">'
                         f'<a href="/book/{book_id}"><em>{html.escape(title)}</em></a> by {html.escape(author)} '
                         f'<span class="price">${price}</span> <span class="{css}">{availability(qty)}</span></li>')
        self.send(200, page("Pinewood Books", "<h2>All our books</h2>\n<ul>\n" + "\n".join(items) + "\n</ul>"))

    def book(self, book_id):
        if book_id not in BOOKS:
            return self.send(404, page("Not found", "<p>Sorry, we don't have that book.</p>"))
        title, author, price = BOOKS[book_id]
        qty = stock_levels().get(book_id)
        body = (f"<h2><em>{html.escape(title)}</em></h2>\n<p>by {html.escape(author)} &middot; "
                f'<span class="price">${price}</span></p>\n'
                f'<p class="stock" data-stock="{"" if qty is None else qty}">{availability(qty)}</p>\n'
                f'<p data-estimate="{book_id}">Delivery: {html.escape(estimate(book_id))}</p>\n'
                f'<form method="post" action="/order"><input type="hidden" name="book" value="{book_id}">'
                f"<button>Order now</button></form>")
        self.send(200, page(title, body))

    def order(self):
        length = min(int(self.headers.get("Content-Length") or 0), 4096)
        form = parse_qs(self.rfile.read(length).decode("utf-8", "replace"))
        try:
            book_id = int(form.get("book", ["0"])[0])
        except ValueError:
            book_id = 0
        if book_id not in BOOKS:
            return self.send(400, page("Not found", "<p>Sorry, we don't have that book.</p>"))
        if not stock_levels().get(book_id):
            return self.send(409, page("Sorry", "<p>Sorry, that book is out of stock.</p>"))
        try:
            order_id = place_order(book_id)
        except OSError as exc:
            print(f"order for book {book_id} failed: {exc}", file=sys.stderr, flush=True)
            return self.send(500, page("Sorry", "<p>Sorry, we couldn't take your order. Please try again.</p>"))
        self.send(200, page("Thank you", f'<h2>Thank you!</h2>\n<p data-order="{order_id}">Order placed: '
                                         f"<strong>{order_id}</strong>. It's on its way to our warehouse.</p>"))

    do_GET = do_HEAD = do_POST = handle_request


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 128


def main():
    parser = argparse.ArgumentParser(description="Pinewood Books storefront")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    server = Server((args.host, args.port), Handler)
    print(f"Pinewood Books storefront listening on http://{args.host}:{args.port} (pid {os.getpid()})", flush=True)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
chmod 0755 "$APP_DIR/app.py"
python3 -m py_compile "$APP_DIR/app.py"
rm -rf "$APP_DIR/__pycache__"
echo 4100 >/var/lib/storefront/order-seq
chown storefront:storefront /var/lib/storefront/order-seq

cat >/etc/systemd/system/storefront.service <<EOF
[Unit]
Description=Pinewood Books storefront
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=storefront
Group=storefront
# Creates /var/cache/storefront for the delivery-estimate cache.
CacheDirectory=storefront
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 $APP_DIR/app.py --port 8080
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

# --- 9. nginx reverse proxy ----------------------------------------------------------
log "Configuring nginx"
cat >/etc/nginx/conf.d/storefront-logformat.conf <<'EOF'
# Access log format with timings: rt = whole request, urt = time spent in the app.
log_format timed '$remote_addr - [$time_local] "$request" $status $body_bytes_sent '
                 'rt=$request_time urt=$upstream_response_time "$http_user_agent"';
EOF

cat >/etc/nginx/sites-available/storefront <<'EOF'
upstream storefront_app {
    server 127.0.0.1:8080;
}

server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    access_log /var/log/nginx/access.log timed;
    error_log  /var/log/nginx/error.log;

    location / {
        proxy_pass http://storefront_app;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/storefront /etc/nginx/sites-enabled/storefront

# --- 10. Start everything and prove it works -------------------------------------------
log "Starting services"
systemctl daemon-reload
systemctl start warehouse-sim.service # the first stock feed
systemctl start larch-sync.service    # ...fetched once, so the shop has stock levels
systemctl enable --now warehouse-sim.timer larch-sync.timer larch-ship.service storefront.service >/dev/null 2>&1
nginx -t -q
systemctl enable nginx >/dev/null 2>&1
# Restart, not reload: after a reload, the old workers keep answering for a moment.
systemctl restart nginx

fail() {
  echo "ERROR: baseline smoke test failed: $*. The lab can't be built." >&2
  journalctl -u storefront -u larch-ship -u larch-sync -u warehouse-sim -n 40 --no-pager >&2 || true
  exit 1
}

log "Smoke test"
code=000
healthy=false
for _ in $(seq 1 30); do
  response=$(curl -s -m 5 -w '\n%{http_code}' http://127.0.0.1/ || true)
  code=${response##*$'\n'}
  if [[ $code == 200 && $response == *"Pinewood Books"* && $response == *'data-stock="14"'* ]]; then
    healthy=true
    break
  fi
  sleep 1
done
$healthy || fail "home page returned HTTP $code, or no stock levels"

# A book page with a real delivery estimate, quickly, even on a first visit.
start=$(date +%s%N)
book=$(curl -s -m 10 http://127.0.0.1/book/3 || true)
took_ms=$((($(date +%s%N) - start) / 1000000))
[[ $book == *"In stock: ships tomorrow."* ]] || fail "book page has no delivery estimate"
((took_ms < 1500)) || fail "book page took ${took_ms} ms"

# An order reaches the warehouse, and the warehouse acknowledges it.
order=$(curl -s -m 10 -d book=5 http://127.0.0.1/order || true)
[[ $order =~ data-order=\"(PB-[0-9]+-[0-9]+)\" ]] || fail "placing an order didn't work"
order_id=${BASH_REMATCH[1]}
for _ in $(seq 1 15); do
  [[ -e $DROP/inbox/$order_id.order ]] && break
  sleep 1
done
[[ -e $DROP/inbox/$order_id.order ]] || fail "larch-ship didn't send order $order_id"
systemctl start warehouse-sim.service
[[ -e $SIM_STATE/received/$order_id.order && -e $DROP/acks/$order_id.ack ]] ||
  fail "the warehouse didn't receive order $order_id"
[[ -e $SPOOL/sent/$order_id.order ]] || fail "order $order_id isn't filed as sent"

# The stock feed comes back with one book fewer, and the shop shows it.
systemctl start larch-sync.service || fail "larch sync failed"
[[ $(curl -s -m 5 http://127.0.0.1/ || true) == *'data-book="5" data-stock="10"'* ]] ||
  fail "the shop doesn't show the warehouse's new stock level"

# Admin commands work, as Larch's docs say to run them.
reconcile=$(runuser -u sam -- sudo -n -u larch larch admin reconcile </dev/null 2>&1 || true)
[[ $reconcile == *"Nothing to do."* ]] || fail "larch admin reconcile: $reconcile"
[[ -z $(systemctl show -p NextElapseUSecRealtime --value larch-sync.timer | tr -d ' ') ]] &&
  fail "the stock sync isn't scheduled"

# Remember what the vendor's binary and the simulator look like, for lab-check.
sha256sum "$LARCH" /usr/local/sbin/warehouse-sim >/var/lib/lab/checksums
chmod 0600 /var/lib/lab/checksums

log "Healthy baseline is up: stock syncs, orders reach the warehouse, book pages are fast"
