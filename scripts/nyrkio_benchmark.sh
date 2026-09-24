#!/usr/bin/env bash
# nyrkio_benchmark.sh — benchmark a MariaDB commit with sql-bench and upload
# aggregated results to nyrkio.com
#
# Usage:
#   NYRKIO_JWT_TOKEN=<jwt> ./scripts/nyrkio_benchmark.sh --ref <ref> [options]
#
#   --ref REF           branch, tag, commit SHA, PR number (123 / #123), or full
#                       PR URL (https://github.com/<owner>/<repo>/pull/<N>)
#   --retrospective     benchmark every commit in the ref's history, oldest first
#                       (each commit: incremental rebuild + bench run — slow on purpose)
#   --limit N           cap commits in retrospective mode (0 = no cap)
#   --test-name NAME    Nyrkiö test name (default: mariadb_server/benchmark)
#   --full              run sql-bench with full limits (default: --small-test)
#   --dummy             upload simulated metrics instead of real sql-bench data
#                       (upload-plumbing tests only — never use for real data)
#   --dry-run           build nyrkio_payload.json but do not POST
#
# Env:
#   NYRKIO_JWT_TOKEN     required unless --dry-run (nyrkio.com -> user menu -> User Settings)
#   NYRKIO_API_ROOT      default https://nyrkio.com/api/v0
#   NYRKIO_MYSQL_SOCKET  socket of an already-running mysqld to attach to
#                        (skips build/start/stop; the server needs a 'test' db)
#   NYRKIO_MYSQL_USER    benchmark DB user (default: root, no password)
#   NYRKIO_MYSQLD        path to mysqld (default: BUILD/mysqld)
#   NYRKIO_NO_BUILD      set to skip auto-building MariaDB when mysqld is missing
#
# Dependencies for the real benchmark: cmake, gcc, libssl-dev, zlib1g-dev,
# perl DBI + DBD::MariaDB (apt: libdbi-perl libdbd-mariadb-perl)

set -euo pipefail

API_ROOT="${NYRKIO_API_ROOT:-https://nyrkio.com/api/v0}"
TEST_NAME="mariadb_server/benchmark"
REF="" RETRO=0 LIMIT=0 DRY_RUN=0 DUMMY=0 FULL=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: nyrkio_benchmark.sh --ref REF [--retrospective] [--limit N] [--test-name NAME]
                           [--full] [--dummy] [--dry-run]
  REF: branch, tag, commit SHA, PR number (123 / #123), or full PR URL
USAGE
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --ref)           [[ $# -ge 2 ]] || die "--ref needs a value"; REF=$2; shift 2 ;;
    --retrospective) RETRO=1; shift ;;
    --limit)         [[ $# -ge 2 ]] || die "--limit needs a value"; LIMIT=$2; shift 2 ;;
    --test-name)     [[ $# -ge 2 ]] || die "--test-name needs a value"; TEST_NAME=$2; shift 2 ;;
    --full)          FULL=1; shift ;;
    --dummy)         DUMMY=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               usage; die "unknown argument: $1" ;;
  esac
done
[[ -n $REF ]] || { usage; exit 2; }
[[ $LIMIT =~ ^[0-9]+$ ]] || die "--limit must be a non-negative integer"

command -v curl >/dev/null 2>&1 || die "curl is required"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "must run inside a git repo"
if (( ! DRY_RUN )); then
  [[ -n ${NYRKIO_JWT_TOKEN:-} ]] || die "NYRKIO_JWT_TOKEN is not set (nyrkio.com -> user menu -> User Settings; or use --dry-run)"
fi

ORIGIN_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's#^git@github\.com:##; s#^https?://github\.com/##; s#\.git$##' || true)
[[ -n $ORIGIN_REPO ]] || ORIGIN_REPO="iVegas/mariadb_server"

# --- normalize ref: branch/tag/SHA or PR (number or full URL) -----------------
MODE=branch
PR_REPO="" PR_NUM=""
if [[ $REF =~ ^https?://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
  MODE=pr
  PR_REPO="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  PR_NUM="${BASH_REMATCH[3]}"
elif [[ $REF =~ ^#?([0-9]+)$ ]]; then
  MODE=pr
  PR_REPO="$ORIGIN_REPO"
  PR_NUM="${BASH_REMATCH[1]}"
fi

if [[ $MODE == pr ]]; then
  if [[ $PR_REPO == "$ORIGIN_REPO" ]]; then
    git fetch --quiet --depth 1 origin "pull/${PR_NUM}/head:refs/nyrkio/pr-${PR_NUM}" \
      || die "cannot fetch PR #$PR_NUM from $PR_REPO"
  else
    git fetch --quiet --depth 1 "https://github.com/${PR_REPO}.git" \
      "pull/${PR_NUM}/head:refs/nyrkio/pr-${PR_NUM}" \
      || die "cannot fetch PR #$PR_NUM from $PR_REPO (public?)"
  fi
  TARGET="refs/nyrkio/pr-${PR_NUM}"
  BRANCH_LABEL="pr-${PR_NUM}"
  ENDPOINT="${API_ROOT}/pulls/${PR_REPO}/${PR_NUM}/result/${TEST_NAME}"
else
  # branch, tag, or SHA — plain SHAs cannot be fetched by name
  if [[ ! $REF =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    git fetch --quiet origin "$REF" || die "cannot fetch ref '$REF' from origin"
  fi
  TARGET="$REF"
  BRANCH_LABEL="$REF"
  ENDPOINT="${API_ROOT}/result/${TEST_NAME}"
fi

# --- sql-bench real benchmark -------------------------------------------------
ROOT=$(git rev-parse --show-toplevel)
SQL_BENCH="$ROOT/sql-bench"
MYSQLD="${NYRKIO_MYSQLD:-$ROOT/BUILD/mysqld}"
MYSQLADMIN="$(dirname "$MYSQLD")/mysqladmin"
BENCH_USER="${NYRKIO_MYSQL_USER:-root}"
RUN_FILE="$SQL_BENCH/output/RUN-mariadb-nyrkio"
DATADIR="" MYSQLD_PID=""

cleanup() {
  # stop a leftover self-started server (attach mode never sets these)
  if [[ -n $MYSQLD_PID ]]; then
    kill "$MYSQLD_PID" 2>/dev/null || true
    wait "$MYSQLD_PID" 2>/dev/null || true
  fi
  [[ -n $DATADIR ]] && rm -rf "$DATADIR"
}
trap cleanup EXIT

ensure_mysqld() {
  [[ -x $MYSQLD ]] && return
  [[ -n ${NYRKIO_NO_BUILD:-} ]] && die "mysqld not found at $MYSQLD (set NYRKIO_MYSQLD, or unset NYRKIO_NO_BUILD to auto-build)"
  command -v cmake >/dev/null 2>&1 || die "cmake is required to build MariaDB"
  printf 'building MariaDB (cmake, this can take a while)...\n'
  cmake -S "$ROOT" -B "$ROOT/BUILD" -DCMAKE_BUILD_TYPE=Release
  cmake --build "$ROOT/BUILD" -j"$(nproc)"
  [[ -x $MYSQLD ]] || die "build finished but $MYSQLD is missing"
}

start_server() {
  DATADIR=$(mktemp -d "${TMPDIR:-/tmp}/nyrkio-bench.XXXXXX")
  "$MYSQLD" --no-defaults --initialize-insecure --datadir="$DATADIR" >/dev/null
  "$MYSQLD" --no-defaults --datadir="$DATADIR" --socket="$DATADIR/mysql.sock" \
            --skip-networking --pid-file="$DATADIR/mysqld.pid" >/dev/null 2>&1 &
  MYSQLD_PID=$!
  local i
  for i in $(seq 1 60); do
    "$MYSQLADMIN" --no-defaults --socket="$DATADIR/mysql.sock" ping >/dev/null 2>&1 && return
    kill -0 "$MYSQLD_PID" 2>/dev/null || die "mysqld died during startup (datadir: $DATADIR)"
    sleep 1
  done
  die "mysqld not ready after 60s (datadir: $DATADIR)"
}

stop_server() {
  "$MYSQLADMIN" --no-defaults --socket="$DATADIR/mysql.sock" shutdown 2>/dev/null || true
  wait "$MYSQLD_PID" 2>/dev/null || true
  MYSQLD_PID=""
  rm -rf "$DATADIR"
  DATADIR=""
}

parse_run_file() {
  # "Totals per operation:" table:  op seconds usr sys cpu tests  (last row: TOTALS)
  # -> JSON array of metrics, one per operation (unit: s, lower is better)
  local rows first line name val json=""
  rows=$(awk '
    /^Totals per operation:/ { in_table = 1; next }
    in_table && $1 == "Operation" { next }
    in_table && $1 == "TOTALS"    { printf "total\t%s\n", $2; exit }
    in_table && NF >= 2           { printf "%s\t%s\n", $1, $2 }
  ' "$RUN_FILE")
  [[ -n $rows ]] || die "no 'Totals per operation' table found in $RUN_FILE"
  while IFS=$'\t' read -r name val; do
    val=$(LC_ALL=C awk -v v="$val" 'BEGIN { printf "%.3f", v }')   # LC_ALL=C: locale-safe decimal point
    [[ -n $json ]] && json+=","
    json+=$(printf '{"name":"%s","unit":"s","value":%s,"direction":"lower_is_better"}' "$name" "$val")
  done <<< "$rows"
  printf '[%s]' "$json"
}

run_sql_bench() {
  command -v perl >/dev/null 2>&1 || die "perl is required (apt: perl libdbi-perl libdbd-mariadb-perl)"
  perl -MDBI -e 1 2>/dev/null            || die "perl DBI module missing (apt: libdbi-perl)"
  perl -MDBD::MariaDB -e 1 2>/dev/null   || die "perl DBD::MariaDB missing (apt: libdbd-mariadb-perl)"

  local small=""
  (( FULL )) || small="--small-test"
  local socket
  if [[ -n ${NYRKIO_MYSQL_SOCKET:-} ]]; then
    socket=$NYRKIO_MYSQL_SOCKET    # attach to an existing server: no build/start/stop
  else
    ensure_mysqld
    start_server
    socket="$DATADIR/mysql.sock"
  fi

  (
    cd "$SQL_BENCH"
    cp -f bench-init.pl.sh bench-init.pl   # ponytail: source tree ships .sh names; the perl code requires the extensionless names
    cp -f server-cfg.sh server-cfg
    perl run-all-tests.sh --server=mariadb --user="$BENCH_USER" --socket="$socket" \
      --machine=nyrkio --log $small
  ) || die "sql-bench run failed (see $RUN_FILE)"
  [[ -s $RUN_FILE ]] || die "sql-bench produced no output (expected $RUN_FILE)"

  [[ -z ${NYRKIO_MYSQL_SOCKET:-} ]] && stop_server   # only stop a server we started ourselves
  parse_run_file
}

# ponytail: simulated metrics, for upload-plumbing tests only (explicit --dummy).
run_benchmark_dummy() {
  local tps qps lat
  tps=$((12000 + RANDOM % 400))
  qps=$((60000 + RANDOM % 2000))
  lat=$(LC_ALL=C awk -v r="$RANDOM" 'BEGIN { printf "%.3f", 0.80 + r / 1000 }')
  printf '[{"name":"tps","unit":"tps","value":%d},{"name":"qps","unit":"qps","value":%d},{"name":"avg_latency","unit":"ms","value":%s}]' \
    "$tps" "$qps" "$lat"
}

run_metrics() {
  if (( DUMMY )); then run_benchmark_dummy; else run_sql_bench; fi
}

# --- upload -------------------------------------------------------------------
write_payload() { # $1=sha $2=timestamp $3=branch $4=metrics-json
  printf '[\n  {\n    "timestamp": %s,\n    "metrics": %s,\n    "attributes": {\n      "git_commit": "%s",\n      "branch": "%s",\n      "git_repo": "%s"\n    }\n  }\n]\n' \
    "$2" "$4" "$1" "$3" "$ORIGIN_REPO" > nyrkio_payload.json
}

process_commit() { # $1=sha
  local sha=$1 ts branch metrics
  git checkout --quiet "$sha"
  ts=$(git rev-list -1 --format=%ct HEAD | tail -n 1)   # ponytail: %ct is Unix epoch; rev-list prepends a "commit <sha>" line, keep the last
  branch=$(git branch --show-current)
  [[ -n $branch ]] || branch="$BRANCH_LABEL"
  metrics=$(run_metrics)
  write_payload "$sha" "$ts" "$branch" "$metrics"
  if (( DRY_RUN )); then
    printf '[dry-run] %s (ts=%s) -> %s  payload: nyrkio_payload.json\n' "$sha" "$ts" "$ENDPOINT"
  else
    curl --fail --silent --show-error --request POST \
      --header "Authorization: Bearer ${NYRKIO_JWT_TOKEN}" \
      --header "Content-Type: application/json" \
      --data @nyrkio_payload.json "$ENDPOINT" >/dev/null \
      || die "upload failed for $sha to $ENDPOINT"
    printf 'uploaded %s (ts=%s) -> %s\n' "$sha" "$ts" "$ENDPOINT"
  fi
  sleep 0.1   # ponytail: fixed ~10 req/s pace; raise if nyrkio throttles (429)
}

printf 'ref=%s mode=%s test_name=%s retrospective=%s limit=%s dummy=%s full=%s dry_run=%s\n' \
  "$REF" "$MODE" "$TEST_NAME" "$RETRO" "$LIMIT" "$DUMMY" "$FULL" "$DRY_RUN"

if (( RETRO )); then
  total=$(git rev-list --count "$TARGET")
  (( LIMIT > 0 && LIMIT < total )) && total=$LIMIT
  printf 'retrospective: %s commits (of %s)\n' "$total" "$(git rev-list --count "$TARGET")"
  done=0
  while IFS= read -r sha; do
    process_commit "$sha"
    done=$((done + 1))
  done < <(git rev-list --reverse "$TARGET" | awk -v n="$LIMIT" 'n <= 0 || NR <= n')
  printf 'done: %s commits uploaded\n' "$done"
else
  process_commit "$(git rev-parse --verify "${TARGET}^{commit}")"
fi
