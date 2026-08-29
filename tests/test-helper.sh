#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
log="$test_dir/docker.log"

cat > "$test_dir/docker" <<'FAKE'
#!/bin/bash
set -e
printf '%q ' "$@" >> "$FAKE_DOCKER_LOG"
printf '\n' >> "$FAKE_DOCKER_LOG"

if [[ ${1:-} == "--context" ]]; then shift 2; fi
case "${1:-} ${2:-} ${3:-}" in
"context ls --format")
  echo '{"Current":true,"Description":"Local test","DockerEndpoint":"unix:///var/run/docker.sock","Error":"","Name":"default"}'
  ;;
"context show ") echo default ;;
"ps -aq ") echo abc123 ;;
"system df --format")
  echo '{"Type":"Images","TotalCount":"2","Active":"1","Size":"30MB","Reclaimable":"20MB (66%)"}'
  echo '{"Type":"Build Cache","TotalCount":"1","Active":"0","Size":"4MB","Reclaimable":"4MB"}'
  ;;
"system df -v")
  echo '{"Images":[{"Containers":"0","CreatedSince":"2 days ago","ID":"sha256:111111111111aaaaaaaa","Repository":"demo","SharedSize":"0B","Size":"20MB","Tag":"latest","UniqueSize":"20MB"}],"Containers":[],"Volumes":[{"Driver":"local","Labels":"com.docker.compose.project=demo","Links":"0","Mountpoint":"/data","Name":"demo_data","Size":"12MB"}],"BuildCache":[]}'
  ;;
"info --format ") echo '[]' ;;
"inspect abc123 ")
  echo '[{"Id":"abc123abc123abc123","Name":"/web","Image":"sha256:111111111111aaaaaaaa","Platform":"linux","Created":"2026-01-01T00:00:00Z","Path":"/app","Args":["serve","--token=command-secret"],"Config":{"Image":"demo:latest","Env":["TOKEN=hidden","PORT=80"],"Labels":{"com.docker.compose.project":"demo","com.docker.compose.service":"web","com.docker.compose.project.working_dir":"/tmp/project with spaces","com.docker.compose.project.config_files":"/tmp/project with spaces/compose.yml"}},"HostConfig":{"RestartPolicy":{"Name":"unless-stopped"},"PortBindings":{}},"State":{"Status":"running","ExitCode":0,"OOMKilled":false,"Error":"","StartedAt":"2026-01-01T00:00:01Z","FinishedAt":"0001-01-01T00:00:00Z","Health":{"Status":"healthy","Log":[]}},"RestartCount":1,"NetworkSettings":{"Networks":{"default":{"IPAddress":"172.20.0.2","Aliases":["web"]}}},"Mounts":[{"Type":"volume","Source":"/source","Destination":"/data","RW":true}]}]'
  ;;
"image prune -a") echo 'Total reclaimed space: 20MB' ;;
"builder prune -a") echo 'Total: 4MB' ;;
"volume prune -a") echo 'Total reclaimed space: 12MB' ;;
"image rm 111111111111") echo 'Deleted' ;;
"volume rm demo_data") echo demo_data ;;
"compose --project-directory /tmp/project\\ with\\ spaces") : ;;
*) : ;;
esac
FAKE

cat > "$test_dir/systemctl" <<'FAKE'
#!/bin/bash
[[ ${1:-} == is-enabled ]] && echo enabled
FAKE
chmod +x "$test_dir/docker" "$test_dir/systemctl"

export FAKE_DOCKER_LOG="$log"
state=$(DOCKER_BIN="$test_dir/docker" SYSTEMCTL_BIN="$test_dir/systemctl" "$repo/bin/docker-panel" --verbose)

jq -e '.daemon == "running" and .context == "default" and .localContext == true' >/dev/null <<< "$state"
jq -e '.containers[0].project == "demo" and .containers[0].envKeys == ["PORT", "TOKEN"]' >/dev/null <<< "$state"
jq -e '.containers[0].networks[0].ip == "172.20.0.2" and .containers[0].mounts[0].destination == "/data"' >/dev/null <<< "$state"
jq -e '.storage.images[0].repository == "demo" and .storage.volumes[0].composeProject == "demo"' >/dev/null <<< "$state"
jq -e '.storage.images[0].id == "111111111111aaaaaaaa"' >/dev/null <<< "$state"
if grep -q 'hidden' <<< "$state"; then
  echo "secret environment value leaked into state" >&2
  exit 1
fi
if grep -q 'command-secret' <<< "$state"; then
  echo "secret command argument leaked into state" >&2
  exit 1
fi
jq -e '.containers[0].command == "/app"' >/dev/null <<< "$state"

: > "$log"
DOCKER_BIN="$test_dir/docker" "$repo/bin/docker-panel" --remove-image \
  --target '111111111111aaaaaaaa' >/dev/null
grep -Fq -- 'image rm 111111111111aaaaaaaa' "$log"

: > "$log"
DOCKER_BIN="$test_dir/docker" "$repo/bin/docker-panel" --context remote --prune --until 168h >/dev/null
grep -Fq -- '--context remote image prune -a -f --filter until=168h' "$log"
grep -Fq -- '--context remote builder prune -a -f --filter until=168h' "$log"

: > "$log"
DOCKER_BIN="$test_dir/docker" "$repo/bin/docker-panel" --pull-redeploy \
  --project-directory '/tmp/project with spaces' \
  --config-files '/tmp/project with spaces/compose.yml' >/dev/null
grep -Fq -- 'compose --project-directory /tmp/project\ with\ spaces -f /tmp/project\ with\ spaces/compose.yml pull --ignore-buildable' "$log"
grep -Fq -- 'compose --project-directory /tmp/project\ with\ spaces -f /tmp/project\ with\ spaces/compose.yml up -d' "$log"

: > "$log"
DOCKER_BIN="$test_dir/docker" "$repo/bin/docker-panel" --compose-task \
  --project-directory '/tmp/project with spaces' \
  --config-files '/tmp/project with spaces/compose.yml' --service web -- bin/rails db:migrate >/dev/null
grep -Fq -- 'run --rm web bin/rails db:migrate' "$log"

echo "helper tests passed"
