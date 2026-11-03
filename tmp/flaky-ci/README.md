# CI timeout investigation (2026-11-02–03)

## Evidence from GitHub Actions

| Run / attempt | Ruby | Test | Error | Test duration |
| --- | --- | --- | --- | --- |
| [41373990199 / 1](https://github.com/nahi/httpclient/actions/runs/41373990199/attempts/1) | 2.5.9 | `TestHTTPClient#test_eof_error_length` | `HTTPClient::SendTimeoutError` at `session.rb:516` | 0.007073 s |
| same | 3.0.7 | `TestHTTPClient#test_get_content` | `HTTPClient::SendTimeoutError` at `session.rb:516`, `test_httpclient.rb:567` | 3.006134 s |
| [41381002067 / 1](https://github.com/nahi/httpclient/actions/runs/41381002067/attempts/1) | 2.6.10 | `TestHTTPClient#test_eof_error_rest` | `HTTPClient::ReceiveTimeoutError` at `session.rb:935` | 0.008193 s |

Both runs succeeded on attempt 2, without changing their run SHA:
`b6a8126a34dca1fbb07c360bd2c71d2915e0d17c` and
`7062fd252c7db0c66b76ba8662043864dbdb52bb`, respectively.

The helper sets connect/send/receive timeouts to 3 seconds. The EOF tests use
`LoopBackSocket` backed by `StringIO`, with no network I/O in their requests.
Consequently, slow DNS, HTTP servers, and external services do not directly
explain those two failures. Their reported durations do not fit expiration of
a fresh 3-second timer. However, test-unit 3.7.8 computes test elapsed time with
`Time.now`, not a monotonic clock; a runner clock adjustment is another possible
explanation for the apparent timing contradiction. Runtime timer cancellation /
exception delivery and clock behavior are hypotheses, not established root causes.
The reproduction script records both monotonic and wall elapsed time on failure.

The Ruby 3.0 failure occurs on the second request (`redirect1`) and does consume
the configured 3 seconds. It may be a separate send/socket or scheduling failure.
The exception covers header generation, request serialization, flush, and timeout
cleanup; its stack alone does not identify a blocked socket write.

`Helper#teardown_server` and `#teardown_proxyserver` request shutdown without
joining the server threads. Overlapping server lifecycles are another hypothesis;
ephemeral ports reduce simple port-reuse conflicts but do not prove clean teardown.
This does not by itself explain a timeout on a memory-backed socket.

## Local experiments

These runs use native Nix-built runtimes on macOS / arm64. All three target
tests were run 1,000 times each (3,000 tests / 12,000 assertions per runtime).
The predecessor sequence runs `test_empty_proxy_env` followed by both EOF tests,
1,000 times, with timing instrumentation disabled (3,000 tests / 3,000 assertions).

| Runtime | Three target tests | Predecessor sequence | 100,000 standard Timeout cycles | Full suite |
| --- | --- | --- | --- | --- |
| 2.5.9 | Pass, 113.83 s | Pass, 9.24 s | Pass, 3.18 s | 257 tests, 875 assertions, 0 failures/errors, 8 omissions |
| 2.6.10 | Pass, 45.65 s | Pass, 43.18 s | Pass, 9.69 s | 257 tests, 873 assertions, 1 Digest POST error, 8 omissions |
| 2.7.8 | Pass, 165.43 s | Pass, 55.72 s | Pass, 73.20 s | 257 tests, 875 assertions, 0 failures/errors, 8 omissions |
| 3.0.7 | Pass, 237.66 s | Pass, 72.62 s | Pass, 35.35 s | 257 tests, 876 assertions, 1 TLS message mismatch, 8 omissions |

Host load varied substantially; these times are not performance comparisons.
Ruby 2.5 results above use the final build with corrected arm64 metadata.
Logs: `/tmp/httpclient-flaky-ci/ruby{25,26,30}-*-final.log` and
`/tmp/httpclient-flaky-ci/ruby27-{repeat,order-repeat,timeout-stress,suite-cert-env}.log`.

The supplied CI timeout failures were not reproduced. This does not exclude
old-runtime or Linux-specific behavior. CI uses Ubuntu / x86_64; local uses
macOS / arm64. Ruby 3.0's local builder uses OpenSSL extension 3.0.2 with
OpenSSL 3.0.12, while the failing CI permits TLS 1.0. Its full-suite failure is
`TestSSL#test_disallow_tlsv1`: expected `tlsv1 alert protocol version`, received
`tlsv1 alert internal error`. It is separate from the timeout failures.

### Timeout failure shape

All three exceptions come through Ruby's standard `Timeout.timeout`. The Ruby
2.5 send failure and Ruby 2.6 receive failure happen in EOF tests backed by
`LoopBackSocket`/`StringIO`; those operations do not use a network socket. This
points away from DNS and a remote service and toward timeout delivery,
scheduling, or runtime/platform behavior, but does not identify which one. The
CI test-unit durations for these failures were 7–8 ms despite 3-second timeout
settings. test-unit 3.7.8 measures elapsed time with `Time.now`, so those values
do not establish that the timer actually fired early. The Ruby 3.0 redirect
failure consumes about 3.006 s while talking to the local WEBrick server and
may be a separate scheduling/server delay.

Gem names and versions in all three failing CI lockfiles were compared with
the local lockfiles and match exactly. CI used Bundler 2.3.27 / 2.4.22 / 2.2.33
for Ruby 2.5 / 2.6 / 3.0. The main local Ruby 3.0 run used Bundler 2.5.23;
`replay-ci-lock.sh` supports replaying the original Bundler and lockfile.
An additional Ruby 3.0.7 run with the original Bundler 2.2.33 and CI lockfile
also passed all 3,000 target tests / 12,000 assertions (103.68 s) and the
3,000-test predecessor sequence / 3,000 assertions (10.27 s), with no failures
or errors. Its loaded gem versions confirm Bundler 2.2.33 and the expected
test-unit 3.7.8 / WEBrick 1.9.2. Log:
`/tmp/httpclient-flaky-ci/ruby30-ci-lock-repeat.log`.
The snapshots in `ci-locks/` were extracted from the failed jobs' printed
lockfiles. The replay adjusts only the local project path and host platform.
Runtime RubyGems and native libraries can still differ from CI.

The first full runs had two deterministic SSL errors because Nix OpenSSL's
`NIX_SSL_CERT_FILE` overrides test changes to `SSL_CERT_FILE`. Removing the
Nix variable fixed both tests. The final wrappers translate that fallback into
`SSL_CERT_FILE` and unset `NIX_SSL_CERT_FILE`, preserving explicit user CA choices.

An earlier Ruby 3.4.7 run with the old timeout.rb also passed 3,000 target tests
and 100,000 timer cycles. That test run inherited Gem environment warnings;
the isolated native-runtime results above are the primary evidence.

The current checkout differs from the first run in SSL configuration and related
tests. The HTTP session code, helper, and these three HTTP tests are unchanged.
Full-suite order and exact CI SHA still matter when comparing reproductions.

### Full suite with CI file order

Rake 13.4.2 builds its test list with `Dir.glob`. Its filesystem enumeration
order on macOS differs from the test-loader command recorded in GitHub's Ubuntu
logs. The initial local full-suite runs therefore did not reproduce the CI
file order. `run-ci-suite.sh` now uses the file order printed in each failed CI
log, the saved CI lockfile, the CI Bundler version, and the same Ruby
test-loader options. The order is overridable with `CI_TEST_FILES` for other CI
runs.

| Runtime and source / CI dependencies | Complete suite | Failed CI test |
| --- | --- | --- |
| Ruby 2.5.9, current checkout / CI lock | 5/5 pass | EOF test passes 5/5 |
| Ruby 2.5.9, exact SHA `b6a8126` / CI lock | 4/5 pass; 1/5 has unrelated Digest and SSL errors | EOF test passes 5/5 |
| Ruby 2.6.10, current checkout / CI lock | 5/5 pass | EOF test passes 5/5 |
| Ruby 2.6.10, exact SHA `7062fd2` / CI lock | 3/5 pass; Digest `ECONNRESET` in 2/5 | EOF test passes 5/5 |
| Ruby 3.0.7, exact SHA `b6a8126` / CI lock | TLS message mismatch in 5/5; Digest `ECONNRESET` in 1/5 | `TestHTTPClient#test_get_content` passes 5/5 |

The exact source SHAs were archived to temporary directories and run with their
CI Bundler, lockfile and test-loader order. None of the three timeout failures
reappeared. The exact 2.6 source adds four SSL-config tests versus the current
checkout; its count (261) matches the CI run. The Ruby 3.0 TLS mismatch is the
known local OpenSSL difference listed above. The intermittent Digest errors
match the independently reproduced WEBrick POST-body/connection-close race;
they are separate from the specified timeout failures.

Logs: `/tmp/httpclient-flaky-ci/ruby25-original-sha-repeats.log`,
`ruby26-original-sha-repeats.log`, and `ruby30-original-sha-repeats.log`.
Current-checkout comparison logs are
`/tmp/httpclient-flaky-ci/ruby25-ci-order-repeats.log` and
`ruby26-ci-order-repeats.log`.

## Linux container replays

The Docker-compatible CLI connects to a local Podman VM running Fedora 44,
kernel `7.1.3-200.fc44.aarch64`, with 5 vCPUs and about 2 GiB of memory. Native
Linux runs used the official Ruby images on `linux/arm64`. The `linux/amd64`
runs used QEMU user-mode emulation on that same ARM64 Linux kernel. These runs
use the exact archived CI source SHAs, Bundler versions, and lockfile gem
versions, but the Ruby binaries are from the Docker images rather than
`ruby/setup-ruby`.

| Runtime / container | Repeated CI failure test(s) | Result |
| --- | --- | --- |
| Ruby 2.5.9, `ruby:2.5.9-buster`, arm64 | `test_eof_error_length` 1,000 times; then `test_empty_proxy_env` + both EOF tests 1,000 times | Pass; 1,000 tests / 1,000 assertions, then 3,000 / 3,000 |
| Ruby 2.6.10, `ruby:2.6.10-bullseye`, arm64 | Both EOF tests and `test_get_content` 1,000 times; then proxy + EOF sequence 1,000 times | Pass; 3,000 tests / 12,000 assertions, then 3,000 / 3,000 |
| Ruby 3.0.7, `ruby:3.0.7-bullseye`, arm64 | `test_get_content` 100 times; then proxy + EOF sequence 100 times | Pass; 100 tests / 1,000 assertions, then 300 / 300 |
| Ruby 2.5.9, `ruby:2.5.9-buster`, amd64 under QEMU | Proxy + EOF sequence 1,000 times, twice | Pass; 3,000 tests / 3,000 assertions per run |
| Ruby 2.6.10, `ruby:2.6.10-bullseye`, amd64 under QEMU | Proxy + EOF sequence 1,000 times, twice | Pass; 3,000 tests / 3,000 assertions per run |

The exact Ruby 2.6.10 CI source and test-file order were also run through the
full suite once in the arm64 container. The two EOF tests and `test_get_content`
passed. After correcting the image's missing OpenSSL default CA file path inside
the ephemeral container, the suite reported 261 tests, 880 assertions, one
failure, one error, and eight omissions. The unrelated failures were:

* `TestAuth#test_basic_auth_post_with_multipart` raised `EPIPE` / `KeepAliveDisconnected`
  while uploading the IO body, even after the test's built-in retries.
* `TestSSL#test_allow_tlsv1` received a TLS protocol-version alert from the
  container's TLS setup.

The first error resembles the separate Digest POST body / early-auth-response
race reproduced on macOS. It broadens the evidence for a WEBrick auth challenge
versus streaming-body fixture problem, but does not explain the CI EOF timeout
failures. The initial full-suite attempt also had CA-path errors because this
image's `OpenSSL::X509::DEFAULT_CERT_FILE` is `/usr/lib/ssl/cert.pem`, which was
absent; setting only `SSL_CERT_FILE` did not change HTTPClient's explicit file
load. A temporary symlink to Debian's CA bundle removed those errors.

None of the supplied timeout failures reproduced in these Linux runs. This
narrows the next comparison to a native Linux x86_64 runner or VM using the
same Ruby build as CI. The amd64 container is emulated, and the Fedora VM kernel
and container Ruby builds differ from GitHub Actions, so these results do not
exclude a CI-specific runtime, kernel, or load interaction. The 1,000-run Ruby
2.6 arm64 target pass that included `test_get_content` took 880 seconds; do not
compare these container durations with CI or the macOS host as performance
measurements.

## Native GitHub-hosted runner replays

The original workflow has no `workflow_dispatch` trigger. The failed jobs from
attempt 1 were no longer eligible for a direct job rerun after attempt 2 had
completed, so the corresponding jobs were rerun from the latest successful
attempts. This used the existing workflow without source or workflow changes;
each invocation ran the complete suite once on the normal GitHub-hosted Ubuntu
runner (`ubuntu-24.04` for these Ruby versions).

| Ruby / source SHA | Original attempt 1 | Later full-suite successes |
| --- | --- | --- |
| 2.5.9 / `b6a8126a34dca1fbb07c360bd2c71d2915e0d17c` | `test_eof_error_length` failed | Attempts 2, 3, 5, and 6 passed |
| 2.6.10 / `7062fd252c7db0c66b76ba8662043864dbdb52bb` | `test_eof_error_rest` failed | Attempts 2, 3, 4, and 5 passed |
| 3.0.7 / `b6a8126a34dca1fbb07c360bd2c71d2915e0d17c` | `test_get_content` failed | Attempts 2, 4, and 7 passed |

The final workflow runs completed successfully:
<https://github.com/nahi/httpclient/actions/runs/41373990199/attempts/7> and
<https://github.com/nahi/httpclient/actions/runs/41381002067/attempts/5>.
Each later attempt reused already-successful matrix jobs and executed only the
selected Ruby job on a fresh hosted runner. These runs confirm the same
CI-managed Ruby/dependency setup can pass repeatedly on native x86_64 Linux,
while the intermittent failures remain unreproduced. They do not identify the
trigger; the next useful experiment would repeat only the failing test sequence
inside a job, which requires adding a temporary repeat-test workflow or
parameterizing the existing workflow.

## Reproduction scripts

### Repeatable Linux experiments and a native-runner workflow draft

`linux-replay.sh` now provides a repeatable container entry point. Source and
lockfile mounts are read-only; Bundler writes its working lockfile inside the
container and caches gems in a dedicated Docker volume per Ruby/architecture.
Adding the container platform is allowed only if every gem name/version still
matches the supplied snapshot. Existing Nix shells remain the local macOS
runtime setup; the container is used to compare Linux execution behavior.

```sh
# Defaults to the failed Ruby 2.6 source SHA and dependency snapshot.
bash tmp/flaky-ci/linux-replay.sh 2.6 1000

# Same timeouts and test bodies, with CPU contention inside a 1-CPU quota.
CPUS=1 LOAD_WORKERS=4 bash tmp/flaky-ci/linux-replay.sh 2.6 1000

# Record timing, timer-thread age/raise origin, and the current test/iteration.
CPUS=1 LOAD_WORKERS=4 NO_TIMING=0 TRACE_TIMEOUT_RAISES=1 \
  bash tmp/flaky-ci/linux-replay.sh 2.6 1000

# Choose a different source, Ruby image, or dependency snapshot explicitly.
SOURCE_DIR="$PWD" LOCKFILE="$PWD/tmp/flaky-ci/ci-locks/ruby-2.6.lock" \
  IMAGE=ruby:2.6.10-bullseye \
  bash tmp/flaky-ci/linux-replay.sh 2.6 1000
```

`TEST_FILE`, `TEST_CLASS`, and comma-separated `TEST_NAMES` select other tests.
`PLATFORM=linux/amd64` requests x86_64 emulation on this ARM64 host; the default
matches the host architecture. `LOAD_WORKERS` creates independent CPU-bound
processes and reaps them on exit. It does not shorten timeouts or inject delays
into tested methods. The runner logs `cpu.max`, `cpu.stat`, and `memory.events`
before and after the test process. CPU contention here is an experimental
condition, not a measured property of the original failed GitHub jobs.

Additional Ruby 2.6.10 / original `7062fd2` Linux ARM64 results:

| CPU quota | CPU competitors | Timeout instrumentation | Result |
| --- | --- | --- | --- |
| 1 CPU | 0 | Off | 3,000 tests / 3,000 assertions, pass; 3.80 s |
| 1 CPU | 4 | Off | 3,000 tests / 3,000 assertions, pass; 42.10 s |
| 1 CPU | 4 | On, including timer creation/raise tracing | 3,000 tests / 3,000 assertions, pass; 58.60 s |
| 1 CPU | 4 | Off, Ruby 2.5.9 / original `b6a8126` | 3,000 tests / 3,000 assertions, pass; 30.71 s |

All repeat `test_empty_proxy_env`, `test_eof_error_length`, and
`test_eof_error_rest` 1,000 times. In the loaded run, `nr_throttled` increased
from 1 to 432, confirming that the quota actually constrained execution.
None reproduced an original CI failure. Logs:
`linux-ruby26-cpu1-control.log`, `linux-ruby26-cpu1-load4.log`, and
`linux-ruby26-cpu1-load4-trace.log`, plus `linux-ruby25-cpu1-load4.log`.

The branch includes the workflow at `.github/workflows/flake-repro.yml` and its
runner/lock snapshots under `script/ci-flake/`; it does not modify HTTPClient
or its test fixtures. It checks out each original SHA separately, uses
`ruby/setup-ruby` on Ubuntu 24.04 x86_64, restores the failed job's
lockfile/Bundler, and repeats the affected sequence with instrumentation off
and on. Logs are uploaded even when a test fails. Ruby 2.5/2.6 use the
proxy+EOF sequence, Ruby 3.0 uses `test_get_content`. CPU competitors default
to zero and can be selected for manual runs. `native-runner.patch` is a
reviewable bundle of these additions.

YAML parsing and `actionlint` succeeded; execution on GitHub is not yet
validated. The initial push to `ci/flake-repro` will trigger this workflow,
because a new `workflow_dispatch` workflow cannot be manually dispatched until
it is available on the default branch. The same push also triggers the existing
push workflow. A local topic branch/commit has been created; it is not pushed
yet, and no PR is being opened.

Current recommendation: collect this targeted, instrumented native x86_64
evidence before changing timeout behavior or increasing the fixture's timeout.
The independently reproduced Digest body-draining patch below remains a
separate fixture fix candidate.

From the repository root, after installing dependencies in the appropriate Nix
shell (see `../legacy-ruby-flake.md`):

```sh
nix develop path:.#ruby25 -c bash tmp/flaky-ci/run.sh 2.5 1000
nix develop path:.#ruby26 -c bash tmp/flaky-ci/run.sh 2.6 1000
nix develop path:.#ruby30 -c bash tmp/flaky-ci/run.sh 3.0 1000
```

For the original CI dependency snapshot and Bundler:

```sh
nix develop path:.#ruby30 -c bash tmp/flaky-ci/replay-ci-lock.sh 3.0 1000
nix develop ./.nix/profiles/all-rubies -c bash tmp/flaky-ci/run-ci-suite.sh 2.6 5
```

`run-ci-suite.sh <ruby> <runs> [lockfile]` repeats the full suite in the file
order recorded in the corresponding CI log. Pass another lockfile to explore a
different dependency combination, or set `CI_TEST_FILES` to a whitespace
separated test-file order. The script uses the Bundler version in that lockfile.

`validate-runtime.sh 2.5` runs setup, both repetition modes, timer stress, and
the full suite; it returns a failure if any stage fails and prints the log path.
Known full-suite failures above are preserved, not automatically retried.

`run.sh` enables the frozen string literal and warning options used in CI.
`TEST_NAMES` selects a comma-separated subset. `NO_TIMING=1` disables the
timeout timing wrapper for a control run. `TRACE_TIMEOUT_RAISES=1` also
records the timer thread's age and the site delivering a timeout exception;
instrumentation changes scheduling, so compare against runs without it.
Both EOF failures occur shortly after `test_empty_proxy_env` in the CI order.
To include that proxy lifecycle in focused repetitions, set
`TEST_NAMES=test_empty_proxy_env,test_eof_error_length,test_eof_error_rest`.

`timeout-stress.rb` tests only the runtime's `Timeout.timeout`, without any gems,
HTTPClient, or WEBrick:

```sh
REPEAT=100000 nix develop path:.#ruby25 -c ruby2.5 tmp/flaky-ci/timeout-stress.rb
YIELD=1 REPEAT=100000 nix develop path:.#ruby26 -c ruby2.6 tmp/flaky-ci/timeout-stress.rb
```

If failures reproduce, compare: unmodified versus joined WEBrick teardown;
native default timeout versus a compatible newer timeout gem; focused tests
versus the full suite; macOS versus Linux with the same pinned flake.
An artificially shortened timeout or deliberately delayed server demonstrates
the exception path, but is not a reproduction of the observed flakiness.

## Additional local flake: Digest POST with an IO body

`TestAuth#test_digest_auth_with_post_io` intermittently raises `ECONNRESET`
while reading the first unauthorized response body. It appeared in full-suite
runs on Ruby 2.6 and 2.7, independently of the supplied timeout failures.
Focused Ruby 2.7 results:

| Fixture variant | Timing wrapper | Errors / repetitions |
| --- | --- | --- |
| Original | On | 163 / 1,000 |
| Join server threads at teardown | On | 171 / 1,000 |
| Read request body before Digest authentication | On | 0 / 1,000 |
| Original | Off | 141 / 1,000 |
| Read request body before Digest authentication | Off | 0 / 1,000 |

WEBrick only drains an unread request via `req.fixup` when both request and
response keep the connection alive. An unauthorized response can close the
connection with request bytes still unread. The results support a request-body /
connection-close race on macOS, independently of server teardown. Packet-level
TCP confirmation has not been performed. This is not evidence that the supplied
CI timeout failures share this cause.

```sh
NO_TIMING=1 TEST_FILE=test/test_auth TEST_CLASS=TestAuth \
TEST_NAMES=test_digest_auth_with_post_io \
nix develop path:.#ruby27 -c bash tmp/flaky-ci/run.sh 2.7 1000
```

Compare with `DRAIN_DIGEST_BODY=1` (read body before authentication) and
`JOIN_SERVER_THREADS=1` (wait for WEBrick shutdown). These are diagnostic
fixture changes in `variants.rb`, not changes applied to repository tests.
`digest-fixture.patch` contains a candidate fixture fix matching the body-draining
experiment; `git apply --check` passed, but the patch has not been applied.
Logs: `/tmp/httpclient-flaky-ci/ruby27-digest-{repeat,join,drain}.log`.
