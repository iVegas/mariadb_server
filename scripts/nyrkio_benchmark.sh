#!/usr/bin/env bash
# nyrkio_benchmark.sh — benchmark MariaDB commits with sql-bench and upload
# aggregated results to nyrkio.com
#
# Usage:
#   NYRKIO_JWT_TOKEN=<jwt> ./scripts/nyrkio_benchmark.sh --ref <ref> [options]
#   NYRKIO_JWT_TOKEN=<jwt> ./scripts/nyrkio_benchmark.sh --ref <ref> --upload DIR
#
#   --ref REF           branch, tag, commit SHA, PR number (123 / #123), or full
#                       PR URL (https://github.com/<owner>/<repo>/pull/<N>)
#   --retrospective     benchmark the ref's first-parent history, oldest first, from the
#                       oldest commit the pinned sql-bench is compatible with (see below).
#                       One run only does a slice of it (--limit/--budget); the slice
#                       ends with outputs (next_since, done) to chain the next run
#   --stride N          retrospective: every Nth commit counting back from the target
#                       (default 1 = every commit; the target itself is always included)
#   --since SHA         retrospective: continue after this commit (a previous run's
#                       next_since; use the same --target/--stride as that run)
#   --target SHA        pin the commit --ref resolves to (a previous run's target output)
#   --limit N           retrospective: at most N commits per run (0 = no cap; commits
#                       that fail to build or bench are skipped)
#   --budget MIN        retrospective: start no new commit after MIN minutes (0 = no cap);
#                       keeps a run inside a CI job time limit
#   --test-name NAME    Nyrkiö test name (default: mariadb_server/benchmark)
#   --full              run sql-bench with full limits (default: --small-test)
#   --dummy             upload simulated metrics instead of real sql-bench data
#                       (upload-plumbing tests only — never use for real data)
#   --dry-run           write payloads to --out-dir but do not POST
#   --out-dir DIR       where payloads are written (default: ./nyrkio_payloads)
#   --upload DIR        do not benchmark: POST every DIR/*.json payload, in name
#                       order, to the endpoint derived from --ref (no git fetch)
#
# Supported range: only commits whose sql-bench setup is DBD::MariaDB based
# (server-cfg.sh has 'DBI:MariaDB', i.e. 10.5.0 and newer) are benchmarked, because
# the pinned sql-bench below is that one. Older history is out of range.
#
# The benchmark never touches the current checkout: each commit is checked out
# into a git worktree under $NYRKIO_WORKDIR and built out of tree there, and
# sql-bench always comes from the current checkout so every commit is measured
# with the same benchmark code.
#
# Env:
#   NYRKIO_JWT_TOKEN     required unless --dry-run (nyrkio.com -> user menu -> User Settings)
#   NYRKIO_API_ROOT      default https://nyrkio.com/api/v0
#   GITHUB_OUTPUT       when set, target/next_since/done are appended to it
#   NYRKIO_WORKDIR       worktree + build dir (default: $RUNNER_TEMP or $TMPDIR /nyrkio-work)
#   NYRKIO_CMAKE_FLAGS   extra cmake flags (appended to the defaults below)
#   NYRKIO_MYSQL_SOCKET  socket of an already-running server to attach to
#                        (skips build/start/stop; the server needs a 'test' db)
#   NYRKIO_MYSQL_USER    benchmark DB user (default: root, no password)
#
# Dependencies: git, curl, jq, cmake, bison, gcc/g++, libncurses-dev, libssl-dev,
# zlib1g-dev, perl DBI + DBD::MariaDB (apt: libdbi-perl; DBD::MariaDB via
# `cpanm DBD::MariaDB` + libmariadb-dev where apt has no libdbd-mariadb-perl)

set -euo pipefail

API_ROOT="${NYRKIO_API_ROOT:-https://nyrkio.com/api/v0}"
TEST_NAME="mariadb_server/benchmark"
REF="" RETRO=0 LIMIT=0 STRIDE=1 BUDGET=0 SINCE="" PIN="" DRY_RUN=0 DUMMY=0 FULL=0 UPLOAD_DIR=""
OUT_DIR="$PWD/nyrkio_payloads"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*" >&2; }

# progress: every long phase announces what runs next and roughly how long it
# takes, and reports its duration; bulky tool output is folded into GitHub
# Actions log groups so these lines stay visible
STEP_TAG="" STEP_START=0
fmt_secs() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }
step() { STEP_START=$SECONDS; log "==> ${STEP_TAG}$*"; }
step_done() { log "==> ${STEP_TAG}$* (took $(fmt_secs $(( SECONDS - STEP_START ))))"; }
group() { [[ -z ${GITHUB_ACTIONS:-} ]] || log "::group::$*"; }
endgroup() { [[ -z ${GITHUB_ACTIONS:-} ]] || log "::endgroup::"; }

usage() {
  cat >&2 <<'USAGE'
usage: nyrkio_benchmark.sh --ref REF [--retrospective] [--stride N] [--since SHA] [--target SHA]
                           [--limit N] [--budget MIN] [--test-name NAME] [--full] [--dummy] [--dry-run] [--out-dir DIR]
       nyrkio_benchmark.sh --ref REF [--test-name NAME] --upload DIR
  REF: branch, tag, commit SHA, PR number (123 / #123), or full PR URL
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --ref)           [[ $# -ge 2 ]] || die "--ref needs a value"; REF=$2; shift 2 ;;
    --retrospective) RETRO=1; shift ;;
    --limit)         [[ $# -ge 2 ]] || die "--limit needs a value"; LIMIT=$2; shift 2 ;;
    --stride)        [[ $# -ge 2 ]] || die "--stride needs a value"; STRIDE=$2; shift 2 ;;
    --since)         [[ $# -ge 2 ]] || die "--since needs a value"; SINCE=$2; shift 2 ;;
    --target)        [[ $# -ge 2 ]] || die "--target needs a value"; PIN=$2; shift 2 ;;
    --budget)        [[ $# -ge 2 ]] || die "--budget needs a value"; BUDGET=$2; shift 2 ;;
    --test-name)     [[ $# -ge 2 ]] || die "--test-name needs a value"; TEST_NAME=$2; shift 2 ;;
    --full)          FULL=1; shift ;;
    --dummy)         DUMMY=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    --out-dir)       [[ $# -ge 2 ]] || die "--out-dir needs a value"; OUT_DIR=$2; shift 2 ;;
    --upload)        [[ $# -ge 2 ]] || die "--upload needs a value"; UPLOAD_DIR=$2; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage; die "unknown argument: $1" ;;
  esac
done
[[ -n $REF ]] || { usage; exit 2; }
[[ $LIMIT =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer"
[[ $BUDGET =~ ^[0-9]+$ ]] || die "--budget must be a non-negative integer"
[[ $STRIDE =~ ^[1-9][0-9]*$ ]] || die "--stride must be a positive integer"
[[ -n $UPLOAD_DIR && $DRY_RUN == 1 ]] && die "--upload and --dry-run are mutually exclusive"

for tool in git curl jq; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "must run inside a git repo"
if (( ! DRY_RUN )); then
  [[ -n ${NYRKIO_JWT_TOKEN:-} ]] || die "NYRKIO_JWT_TOKEN is not set (nyrkio.com -> user menu -> User Settings; or use --dry-run)"
fi

ORIGIN_REPO=$(git remote get-url origin 2>/dev/null \
  | sed -nE 's#^(git@github\.com:|https?://github\.com/)([^/]+/[^/]+)$#\2#p' | sed 's#\.git$##')
[[ -n $ORIGIN_REPO ]] || die "origin is not a github.com remote; cannot tell which repo results belong to"

# --- normalize ref: branch/tag/SHA or PR (number or full URL) -----------------
MODE=branch
PR_REPO="" PR_NUM=""
if [[ $REF =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)/?$ ]]; then
  MODE=pr
  PR_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  PR_NUM="${BASH_REMATCH[3]}"
elif [[ $REF =~ ^#?([0-9]+)$ ]]; then
  MODE=pr
  PR_REPO="$ORIGIN_REPO"
  PR_NUM="${BASH_REMATCH[1]}"
fi

if [[ $MODE == pr ]]; then
  BRANCH_LABEL="pr-${PR_NUM}"
  RESULT_REPO="$PR_REPO"
  ENDPOINT="${API_ROOT}/pulls/${PR_REPO}/${PR_NUM}/result/${TEST_NAME}"
else
  BRANCH_LABEL="$REF"
  RESULT_REPO="$ORIGIN_REPO"
  ENDPOINT="${API_ROOT}/result/${TEST_NAME}"
fi

# --- upload -------------------------------------------------------------------
post_payload() { # $1=payload file
  jq -e 'type == "array" and length > 0 and all(.[]; (.timestamp | type) == "number"
         and (.metrics | type) == "array" and (.attributes.git_commit | type) == "string")' \
    "$1" >/dev/null || die "invalid payload: $1"
  curl --fail --silent --show-error --request POST \
    --header "Authorization: Bearer ${NYRKIO_JWT_TOKEN}" \
    --header "Content-Type: application/json" \
    --data @"$1" "$ENDPOINT" >/dev/null \
    || die "upload of $1 to $ENDPOINT failed"
  log "uploaded $(jq -r '.[0].attributes.git_commit' "$1") -> $ENDPOINT"
}

if [[ -n $UPLOAD_DIR ]]; then
  shopt -s nullglob
  payloads=("$UPLOAD_DIR"/*.json)
  # a retrospective slice can legitimately produce nothing (all commits unbuildable)
  (( ${#payloads[@]} )) || { log "no payloads in $UPLOAD_DIR, nothing to upload"; exit 0; }
  for p in "${payloads[@]}"; do post_payload "$p"; done
  log "done: ${#payloads[@]} payload(s) uploaded"
  exit 0
fi

# --- resolve the ref to a commit ----------------------------------------------
if [[ -n $PIN ]]; then
  git cat-file -e "${PIN}^{commit}" 2>/dev/null || git fetch --quiet origin "$PIN" \
    || die "cannot fetch pinned target $PIN from origin"
  TARGET=$(git rev-parse "${PIN}^{commit}")
elif [[ $MODE == pr ]]; then
  remote=origin
  [[ $PR_REPO == "$ORIGIN_REPO" ]] || remote="https://github.com/${PR_REPO}.git"
  git fetch --quiet "$remote" "pull/${PR_NUM}/head" \
    || die "cannot fetch PR #$PR_NUM from $PR_REPO (public?)"
  TARGET=$(git rev-parse FETCH_HEAD)
elif TARGET=$(git rev-parse --verify --quiet "${REF}^{commit}"); then
  :   # already known locally (local branch/tag or a SHA in the clone)
else
  # remote branch or tag (fetch only updates FETCH_HEAD), or a full SHA
  git fetch --quiet origin "$REF" || die "cannot fetch ref '$REF' from origin"
  TARGET=$(git rev-parse FETCH_HEAD)
fi

# --- supported range: sql-bench compatibility ---------------------------------
sqlbench_ok() { git grep -q 'DBI:MariaDB' "$1" -- sql-bench/server-cfg.sh 2>/dev/null; }
sqlbench_ok "$TARGET" || die "$TARGET has no DBD::MariaDB based sql-bench (pre-10.5): out of the supported range"

emit() { # $1=name $2=value: step output for the orchestrating workflow
  log "output: $1=$2"
  [[ -z ${GITHUB_OUTPUT:-} ]] || printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

# --- sql-bench real benchmark -------------------------------------------------
ROOT=$(git rev-parse --show-toplevel)
WORK="${NYRKIO_WORKDIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nyrkio-work}"
SRC="$WORK/src"        # worktree, re-checked-out per commit (stable path keeps builds incremental)
BUILD="$WORK/build"
BENCH="$WORK/sql-bench"
BENCH_USER="${NYRKIO_MYSQL_USER:-root}"
RUN_FILE="$BENCH/output/RUN-mariadb-nyrkio"
CMAKE_FLAGS=(-DCMAKE_BUILD_TYPE=RelWithDebInfo -DWITH_UNIT_TESTS=OFF -DWITH_EMBEDDED_SERVER=OFF
             -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO -DPLUGIN_CONNECT=NO
             -DPLUGIN_COLUMNSTORE=NO -DPLUGIN_DUCKDB=NO -DPLUGIN_S3=NO)
read -r -a extra_flags <<< "${NYRKIO_CMAKE_FLAGS:-}"
CMAKE_FLAGS+=("${extra_flags[@]}")
DATADIR="" MYSQLD_PID="" MYSQLD="" MYSQLADMIN="" METRICS=""

cleanup() {
  # stop a leftover self-started server (attach mode never sets these)
  if [[ -n $MYSQLD_PID ]]; then
    kill "$MYSQLD_PID" 2>/dev/null || true
    wait "$MYSQLD_PID" 2>/dev/null || true
  fi
  if [[ -n $DATADIR ]]; then rm -rf "$DATADIR"; fi
}
trap cleanup EXIT

first_existing() { # print the first executable among the args
  local f
  for f in "$@"; do [[ -x $f ]] && { printf '%s' "$f"; return 0; }; done
  return 1
}

prepare_source() { # $1=sha
  step "checking out into $SRC and updating submodules"
  mkdir -p "$WORK"
  if [[ ! -e $SRC/.git ]]; then
    git worktree prune
    git worktree add --quiet --detach "$SRC" "$1" >&2
  else
    git -C "$SRC" checkout --quiet --detach --force "$1" >&2
  fi
  # refresh submodules cmake already initialized; cmake initializes missing ones
  git -C "$SRC" submodule sync --quiet --recursive >&2
  git -C "$SRC" submodule update --recursive --depth 1 >&2 \
    || die "cannot update submodules for $1"
  [[ -f $SRC/CMakeLists.txt ]] || die "$1 predates the CMake build (no CMakeLists.txt)"
  step_done "source ready"
}

build_server() {
  command -v cmake >/dev/null 2>&1 || die "cmake is required to build MariaDB"
  if [[ -f $BUILD/CMakeCache.txt ]]; then
    step "building MariaDB: incremental rebuild of the previous build (usually a few minutes)"
  else
    step "building MariaDB: cold build with $(nproc) jobs, expect ~30-45 min on a 4-core hosted runner"
  fi
  group "cmake configure + build output"
  cmake -S "$SRC" -B "$BUILD" "${CMAKE_FLAGS[@]}" >&2
  cmake --build "$BUILD" -j"$(nproc)" >&2
  endgroup
  step_done "build finished"
  # 10.5+ names first, pre-10.5 names as fallback
  MYSQLD=$(first_existing "$BUILD/sql/mariadbd" "$BUILD/sql/mysqld") \
    || die "build finished but no server binary in $BUILD/sql"
  MYSQLADMIN=$(first_existing "$BUILD/client/mariadb-admin" "$BUILD/client/mysqladmin") \
    || die "build finished but no mariadb-admin in $BUILD/client"
}

start_server() {
  local install_db user_opt=()
  install_db=$(first_existing "$BUILD/scripts/mariadb-install-db" "$BUILD/scripts/mysql_install_db") \
    || die "no mariadb-install-db in $BUILD/scripts"
  (( EUID == 0 )) && user_opt=(--user=root)   # mariadbd refuses to run as root otherwise
  DATADIR=$(mktemp -d "${TMPDIR:-/tmp}/nyrkio-data.XXXXXX")
  step "creating a fresh datadir (mariadb-install-db) and starting the server"
  # its chatty "... OK" + securing-the-server advice only matters on failure
  "$install_db" --no-defaults --srcdir="$SRC" --builddir="$BUILD" --datadir="$DATADIR" \
    --auth-root-authentication-method=normal "${user_opt[@]}" >"$DATADIR/install-db.log" 2>&1 \
    || { cat "$DATADIR/install-db.log" >&2; die "mariadb-install-db failed (datadir: $DATADIR)"; }
  "$MYSQLD" --no-defaults --datadir="$DATADIR" --socket="$DATADIR/mysql.sock" \
            --skip-networking --pid-file="$DATADIR/mysqld.pid" \
            --log-error="$DATADIR/error.log" "${user_opt[@]}" >&2 &
  MYSQLD_PID=$!
  local i
  for i in $(seq 1 60); do
    if "$MYSQLADMIN" --no-defaults --user=root --socket="$DATADIR/mysql.sock" ping >/dev/null 2>&1; then
      step_done "server $("$MYSQLD" --version | awk '{ print $3 }') is up"
      return
    fi
    kill -0 "$MYSQLD_PID" 2>/dev/null || { cat "$DATADIR/error.log" >&2 || true; die "server died during startup"; }
    sleep 1
  done
  die "server not ready after 60s (datadir: $DATADIR)"
}

stop_server() {
  "$MYSQLADMIN" --no-defaults --user=root --socket="$DATADIR/mysql.sock" shutdown 2>/dev/null || true
  wait "$MYSQLD_PID" 2>/dev/null || true
  MYSQLD_PID=""
  rm -rf "$DATADIR"
  DATADIR=""
}

parse_run_file() {
  # "Totals per operation:" table:  op seconds usr sys cpu tests [+?]  (last row: TOTALS)
  # -> METRICS: JSON array, one metric per operation (unit: s, lower is better)
  METRICS=$(awk '
    /^Totals per operation:/ { in_table = 1; next }
    in_table && $1 == "Operation" { next }
    in_table && $1 == "TOTALS"    { printf "total\t%s\n", $2; exit }
    in_table && NF >= 2           { printf "%s\t%s\n", $1, $2 }
  ' "$RUN_FILE" | LC_ALL=C jq -R -s -c '
    [ split("\n")[] | select(length > 0) | split("\t")
      | {name: .[0], unit: "s", value: (.[1] | tonumber * 1000 | round / 1000),
         direction: "lower_is_better"} ]')
  [[ $METRICS != "[]" ]] || die "no 'Totals per operation' table found in $RUN_FILE"
}

run_sql_bench() {
  command -v perl >/dev/null 2>&1 || die "perl is required (apt: perl libdbi-perl)"
  perl -MDBI -e 1 2>/dev/null            || die "perl DBI module missing (apt: libdbi-perl)"
  perl -MDBD::MariaDB -e 1 2>/dev/null   || die "perl DBD::MariaDB missing (apt: libdbd-mariadb-perl, or cpanm DBD::MariaDB)"

  local small="" socket
  (( FULL )) || small="--small-test"
  if [[ -n ${NYRKIO_MYSQL_SOCKET:-} ]]; then
    socket=$NYRKIO_MYSQL_SOCKET    # attach to an existing server: no build/start/stop
  else
    build_server
    start_server
    socket="$DATADIR/mysql.sock"
  fi

  # pinned copy of this checkout's sql-bench; the source tree ships .sh names,
  # but (like `make install`) the perl code wants them without the extension:
  # bench-init.pl, server-cfg, and run-all-tests skips test-*.sh entirely
  rm -rf "$BENCH"
  cp -r "$ROOT/sql-bench" "$BENCH"
  local f
  for f in "$BENCH"/*.sh; do mv -f "$f" "${f%.sh}"; done
  mkdir -p "$BENCH/output"
  local ntests
  ntests=$(find "$BENCH" -maxdepth 1 -name 'test-*' ! -name '*-fork' | wc -l)
  if (( FULL )); then
    step "running sql-bench, full limits: $ntests test suites, can take several hours"
  else
    step "running sql-bench --small-test: $ntests test suites, usually a few minutes"
  fi
  log "    each suite prints '<name>: Total time: ...' when it finishes; a pause after '<name>:' is that suite running"
  # no --log: the report goes to the job log as it is produced, and tee keeps
  # the RUN file that parse_run_file reads
  (
    cd "$BENCH"
    perl run-all-tests --server=mariadb --user="$BENCH_USER" --socket="$socket" \
      --machine=nyrkio $small | tee "$RUN_FILE" >&2
  ) || die "sql-bench run failed (see $RUN_FILE)"
  step_done "sql-bench finished"
  [[ -s $RUN_FILE ]] || die "sql-bench produced no output (expected $RUN_FILE)"

  [[ -n ${NYRKIO_MYSQL_SOCKET:-} ]] || stop_server   # only stop a server we started ourselves
  parse_run_file
}

# ponytail: simulated metrics, for upload-plumbing tests only (explicit --dummy).
run_benchmark_dummy() {
  METRICS=$(jq -n -c --argjson r "$RANDOM" '[
    {name: "tps", unit: "tps", value: (12000 + $r % 400), direction: "higher_is_better"},
    {name: "qps", unit: "qps", value: (60000 + $r % 2000), direction: "higher_is_better"},
    {name: "avg_latency", unit: "ms", value: ((800 + $r % 100) / 1000), direction: "lower_is_better"}]')
}

write_payload() { # $1=file $2=sha $3=timestamp $4=branch
  jq -n --argjson ts "$3" --argjson metrics "$METRICS" --arg sha "$2" --arg branch "$4" \
        --arg repo "https://github.com/${RESULT_REPO}" \
    '[{timestamp: $ts, metrics: $metrics,
       attributes: {git_commit: $sha, branch: $branch, git_repo: $repo}}]' > "$1"
}

process_commit() { # $1=sha $2=sequence number
  local sha=$1 ts payload
  ts=$(git show -s --format=%ct "$sha")   # commit time, Unix epoch
  STEP_TAG="[$2/$TOTAL ${sha:0:10}] "
  log "==> ${STEP_TAG}$(git show -s --format='%cs %s' "$sha")"
  if (( DUMMY )); then
    run_benchmark_dummy
  else
    [[ -n ${NYRKIO_MYSQL_SOCKET:-} ]] || prepare_source "$sha"
    run_sql_bench
  fi
  payload=$(printf '%s/%05d-%s.json' "$OUT_DIR" "$2" "$sha")
  write_payload "$payload" "$sha" "$ts" "$BRANCH_LABEL"
  if (( DRY_RUN )); then
    log "[dry-run] $sha (ts=$ts) -> $ENDPOINT  payload: $payload"
  else
    post_payload "$payload"
  fi
}

log "ref=$REF mode=$MODE target=$TARGET test_name=$TEST_NAME retrospective=$RETRO limit=$LIMIT dummy=$DUMMY full=$FULL dry_run=$DRY_RUN"
if (( RETRO )) && [[ -n ${NYRKIO_MYSQL_SOCKET:-} ]]; then
  die "--retrospective needs a per-commit build; it cannot attach to NYRKIO_MYSQL_SOCKET"
fi
mkdir -p "$OUT_DIR"

if (( RETRO )); then
  # oldest supported commit: binary search on the first-parent chain (sql-bench
  # compatibility only ever turns on going forward in time)
  mapfile -t HISTORY < <(git rev-list --first-parent "$TARGET")   # newest first
  lo=0 hi=$(( ${#HISTORY[@]} - 1 ))
  if sqlbench_ok "${HISTORY[$hi]}"; then
    lo=$hi
  else
    while (( hi - lo > 1 )); do
      mid=$(( (lo + hi) / 2 ))
      if sqlbench_ok "${HISTORY[$mid]}"; then lo=$mid; else hi=$mid; fi
    done
  fi
  log "supported range: ${HISTORY[$lo]:0:10} .. ${TARGET:0:10} ($(( lo + 1 )) first-parent commits, stride $STRIDE)"
  # every STRIDE-th commit from the target back to the floor, then oldest first
  mapfile -t commits < <(printf '%s\n' "${HISTORY[@]:0:lo+1}" | awk -v s="$STRIDE" '(NR - 1) % s == 0' | tac)
  if [[ -n $SINCE ]]; then
    [[ " ${commits[*]} " == *" $SINCE "* ]] || die "--since $SINCE is not in the range (different --target or --stride than the previous run?)"
    mapfile -t commits < <(printf '%s\n' "${commits[@]}" | awk -v c="$SINCE" 'seen { print } $0 == c { seen = 1 }')
  fi
  REMAINING=${#commits[@]}
  TOTAL=$REMAINING
  (( LIMIT > 0 && LIMIT < TOTAL )) && TOTAL=$LIMIT
  log "retrospective: $REMAINING commits left, this run does up to $TOTAL, oldest first"
  # one commit that does not build/bench (too old, or broken) must not end the
  # history run: each commit runs in its own subshell, with its own cleanup
  # (set +e around it: set -e inside a subshell tested by `if` would be ignored)
  skipped=() DONE_COUNT=0 LAST="$SINCE"
  for (( i = 0; i < TOTAL; i++ )); do
    if (( i > 0 && BUDGET > 0 && SECONDS >= BUDGET * 60 )); then
      log "time budget of ${BUDGET}m used up, leaving the rest to the next run"
      break
    fi
    set +e
    ( set -e; trap cleanup EXIT; process_commit "${commits[$i]}" "$((i + 1))" )
    rc=$?
    set -e
    (( rc == 0 )) || { skipped+=("${commits[$i]}"); log "skipped ${commits[$i]} (exit $rc), continuing"; }
    LAST=${commits[$i]}
    DONE_COUNT=$(( i + 1 ))
  done
  log "done: $(( DONE_COUNT - ${#skipped[@]} )) of $DONE_COUNT commits benchmarked this run"
  if (( ${#skipped[@]} )); then log "skipped: ${skipped[*]}"; fi
  (( DONE_COUNT > ${#skipped[@]} )) || log "warning: no commit of this run could be benchmarked"
  emit target "$TARGET"
  emit next_since "$LAST"
  if (( DONE_COUNT < REMAINING )); then emit done false; else emit done true; fi
else
  TOTAL=1
  process_commit "$TARGET" 1
  emit target "$TARGET"
  emit done true
fi
