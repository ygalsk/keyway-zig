#!/bin/bash
#
# Bring up the HTTP Garden with keyway registered as a transducer, then drop
# into its REPL. The garden is cloned into a scratch dir rather than vendored —
# it is a 40-image Docker fleet, not a dependency.
#
#   ./tests/garden/run.sh                  # keyway + a default comparison set
#   ./tests/garden/run.sh nginx haproxy    # keyway + only these
#
# In the REPL, the payload keyway forwarded is what gets compared:
#   payload 'GET / HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n' | transduce keyway | fanout | grid
#
# Requires: docker, uv, and ~10 GB of disk for the image fleet.

set -euo pipefail

# Pinned so a garden-side change can't silently alter what we compare against.
GARDEN_REPO='https://github.com/narfindustries/http-garden'
GARDEN_REF='main'
GARDEN_DIR="${GARDEN_DIR:-${TMPDIR:-/tmp}/http-garden}"

KEYWAY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KEYWAY_REPO="$(git -C "$KEYWAY_ROOT" remote get-url origin | sed -e 's#^git@github.com:#https://github.com/#' -e 's#\.git$##')"
KEYWAY_BRANCH="$(git -C "$KEYWAY_ROOT" rev-parse --abbrev-ref HEAD)"
KEYWAY_COMMIT="$(git -C "$KEYWAY_ROOT" rev-parse HEAD)"

# The garden builds every target from a git URL, so it can only see commits
# that are actually pushed. A dirty tree would be silently ignored.
if ! git -C "$KEYWAY_ROOT" merge-base --is-ancestor "$KEYWAY_COMMIT" "origin/$KEYWAY_BRANCH" 2>/dev/null; then
    echo "error: HEAD ($KEYWAY_COMMIT) is not pushed to origin/$KEYWAY_BRANCH." >&2
    echo "       The garden clones keyway from GitHub; push first." >&2
    exit 1
fi

if [ ! -d "$GARDEN_DIR" ]; then
    git clone --depth 1 --branch "$GARDEN_REF" "$GARDEN_REPO" "$GARDEN_DIR"
fi

rm -rf "$GARDEN_DIR/images/keyway"
cp -r "$(cd "$(dirname "$0")" && pwd)" "$GARDEN_DIR/images/keyway"

GARDEN_DIR="$GARDEN_DIR" \
KEYWAY_REPO="$KEYWAY_REPO" \
KEYWAY_BRANCH="$KEYWAY_BRANCH" \
KEYWAY_COMMIT="$KEYWAY_COMMIT" \
python3 - <<'PY'
import os
import yaml

path = os.path.join(os.environ['GARDEN_DIR'], 'docker-compose.yml')
compose = yaml.safe_load(open(path))
compose['services']['keyway'] = {
    'build': {
        'context': './images/keyway',
        'args': {
            'APP_REPO': os.environ['KEYWAY_REPO'],
            'APP_BRANCH': os.environ['KEYWAY_BRANCH'],
            'APP_VERSION': os.environ['KEYWAY_COMMIT'],
            'CONFIG_FILE': 'keyway.lua',
            'START_SCRIPT': 'start.sh',
        },
    },
    # io_uring needs an unconfined seccomp profile; the default docker profile
    # blocks io_uring_setup and keyway's workers die on startup.
    'security_opt': ['seccomp:unconfined'],
    'volumes': ['./tools:/tools'],
    'x-props': {'role': 'transducer'},
}
yaml.safe_dump(compose, open(path, 'w'), sort_keys=True)
print(f'registered keyway @ {os.environ["KEYWAY_COMMIT"][:12]} as a transducer')
PY

cd "$GARDEN_DIR"
echo "starting the fleet — run './garden.sh repl' from $GARDEN_DIR in another shell"
exec ./garden.sh start --build keyway ${@:-nginx haproxy hyper gunicorn}
