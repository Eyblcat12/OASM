# Shared by the snapshot exporter and restorer, after changing to the repo root.
export MSYS2_ARG_CONV_EXCL='*'
compose=(bash ./compose.sh)
snapshot_files=(postgres.dump counts.txt workspace-id.txt rustfs-data.tar.gz audit-archive.tar.gz oasm-images.tar)
data_volumes=(rustfs-data audit-archive)
application_images=(local/oasm-api:poc-2e12e49 local/oasm-console:poc-2e12e49)

read_project_name() {
    local name
    name=$("${compose[@]}" config | sed -nE "s/^name: [\"']?([a-z0-9][a-z0-9_-]*)[\"']?$/\1/p") || return
    if [[ ! $name =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        printf 'Could not determine the Compose project name.\n' >&2
        return 1
    fi
    printf '%s\n' "$name"
}

count_snapshot_rows() {
    local workspace_id=$1
    shift
    "${compose[@]}" exec -T postgres psql -X -A -t -v ON_ERROR_STOP=1 \
        -v "project_workspace_id=$workspace_id" "$@" -U postgres -d open_asm < counts.sql
}
