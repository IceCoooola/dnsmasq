# dnsmasq

Single-binary DNS forwarder/cache + DHCPv4/DHCPv6 + router-advertisement + TFTP server for
small networks. Plain C, no C++, no dependencies beyond libc for the default build. Note 
that upstream takes patches on the dnsmasq-discuss mailing list, so a GitHub PR here reaches nobody.

## Layout

- `src/` — the whole daemon, one flat directory. Entry point is `main()` in `src/dnsmasq.c`
  (startup + the `poll()` event loop). `option.c` parses the command line and config files
  (6k lines, the biggest file). `forward.c` upstream forwarding, `cache.c` the DNS cache,
  `rfc1035.c` DNS packet build/parse, `rfc2131.c`+`dhcp.c` DHCPv4, `rfc3315.c`+`dhcp6.c` DHCPv6,
  `radv.c` router advertisements, `tftp.c`, `dnssec.c`, `auth.c` authoritative DNS.
  OS plumbing: `netlink.c` (Linux) vs `bpf.c` (BSD/macOS).
- `src/dnsmasq.h` — the one shared header. Every cross-file prototype lives here, grouped under
  `/* file.c */` comments; `struct daemon` is the single global config/state object
  (`daemon->...` everywhere); `OPT_*` are the boolean-option bit numbers.
- `src/config.h` — compile-time tunables (`CACHESIZ`, `FTABSIZ`, ...), the `HAVE_*` / `NO_*`
  feature switches, and OS detection (`HAVE_LINUX_NETWORK` / `HAVE_BSD_NETWORK`).
- `Makefile` at the root (no configure step) plus `bld/` helpers: `pkg-wrapper` turns `HAVE_*`
  into pkg-config flags, `get-version` takes the version string from `git describe`.
- `man/dnsmasq.8` — the reference for every option. `dnsmasq.conf.example`, `FAQ`, `doc.html`.
- `po/` gettext translations. `contrib/` third-party scripts/tools, not built by the root Makefile.
- `debian` → symlink into `submodules/dnsmasq-debian`, an un-initialised submodule. Dangling by default.

## Commands (from the repo root)

```sh
make                                   # ~5 s; builds src/dnsmasq. Objects land in src/, not a build dir
./src/dnsmasq --version                # second line lists what got compiled in
make COPTS=-DNO_DHCP                   # feature switches go through COPTS; changing COPTS triggers a
                                       #   full rebuild on its own (via the src/.copts_* stamp)
make COPTS="-DHAVE_DNSSEC -I/opt/homebrew/include" LDFLAGS=-L/opt/homebrew/lib   # macOS, needs brew nettle+gmp
make COPTS=-DHAVE_DNSSEC               # Linux, needs libnettle-dev
make all-i18n COPTS=-I/opt/homebrew/include LDFLAGS=-L/opt/homebrew/lib LIBS=-lintl  # macOS gettext build
make clean
```

**There is no test suite, no linter, and no CI.** "Tested" means all three of:

```sh
make 2>&1 | grep -E 'warning:|error:'           # expect nothing on gcc/Linux; see known clang warnings below
./src/dnsmasq --test -C dnsmasq.conf.example    # prints "syntax check OK"
./src/dnsmasq -d -p 5355 -C /dev/null --no-resolv --no-hosts --address=/agent.test/10.9.8.7 \
    --log-queries --log-facility=- --pid-file= & pid=$!   # foreground, high port, no root, touches no files
sleep 1; dig +short @127.0.0.1 -p 5355 agent.test   # expect 10.9.8.7, and a "query[A]" line in the log
kill $pid                                        # not `kill %1`: job control is off in non-interactive shells
```

Binary-size check for a change that adds code: `make baseline` before, `make bloatcheck` after.
Linux only: on macOS it has no `readelf` and `size` rounds to whole pages, so it always reports 0.

## Conventions

- GNU/Emacs C style: 2-space indent, braces on their own line indented 2 past the `if`, a tab
  wherever indentation reaches 8 columns. Files mix tabs and spaces on purpose; never re-indent,
  and match the surrounding lines. No clang-format, no `.editorconfig`.
- Every `.c` starts with `#include "dnsmasq.h"`. Optional subsystems are wrapped whole in
  `#ifdef HAVE_X ... #endif` so a disabled feature compiles to an empty object (`dnssec.c`,
  `tftp.c`, `netlink.c`, `inotify.c`, `ipset.c`, `nftset.c`, `conntrack.c`, `dbus.c`, `ubus.c`).
- Adding a `--option` touches four places in `src/option.c` and the docs:
  1. `#define LOPT_NAME <next free number>` (the list near the top, currently ends at 391);
  2. a `{ "name", has_arg, 0, LOPT_NAME }` row in `opts[]`;
  3. a `usage[]` row: `{ LOPT_NAME, OPT_X, NULL, gettext_noop("Help text."), NULL }` for a boolean
     (add `#define OPT_X` in `dnsmasq.h` and bump `OPT_LAST`; `one_opt()` then sets the bit for you),
     or `{ LOPT_NAME, ARG_ONE or ARG_DUP, "<arg>", ... }` plus a `case LOPT_NAME:` in `one_opt()`
     that stores into `daemon->` for an option with a value;
  4. a `.TP` / `.B --name` block in `man/dnsmasq.8`, and a commented example in `dnsmasq.conf.example`
     if users would set it in the config file.
- User-visible strings are wrapped: `_("...")` in code, `gettext_noop("...")` in static tables.
  Option-parse errors: `ret_err(_("..."))`. Logging: `my_syslog(LOG_WARNING, _("..."), ...)`.
  Fatal startup errors: `die(_("..."), arg, EC_BADCONF|EC_BADNET|...)`.
- Memory: `safe_malloc()` at startup (dies on failure), `whine_malloc()` at runtime (logs, returns
  NULL, caller copes). Never bare `malloc()` in daemon code.
- Defaults are `#define`s in `config.h`, applied in `read_opts()` at the bottom of `option.c`.
  The man page states defaults, so a changed default is a man-page change too.
- Commit messages: one summary line, imperative; body credits reporters ("Thanks to X for ...")
  and references earlier commits by full 40-char SHA.

## Guardrails

- Do not edit `CHANGELOG`: the maintainer writes it at release time, grouped by version.
  Do not touch `CHANGELOG.archive`, `VERSION` (a `$Format:%d$` git export placeholder, not a
  version number), or `po/*.po` (regenerated by `make merge` / msgmerge).
- Do not `git submodule update --init` and do not "fix" the dangling `debian` symlink.
- Do not `make install` or use `sudo`. Nothing here needs root: run with `-d -p <high port>` as above.
- Known pre-existing clang (macOS) warnings on a clean build: `util.c` -Wnull-pointer-subtraction
  (5), `edns0.c:521`, `dnsmasq.c:746`, `helper.c:112`. Leave them alone in unrelated changes.
- A macOS `make` does **not** compile-check the Linux-only files (`netlink.c`, `inotify.c`,
  `ipset.c`, `nftset.c`, `conntrack.c`): they are empty objects here. If you change them on macOS,
  say explicitly that they were not compiled. `contrib/lease-tools` is Linux-only for the same reason.
