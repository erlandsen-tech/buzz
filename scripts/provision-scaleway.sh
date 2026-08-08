#!/usr/bin/env bash
set -euo pipefail

# Deployment parameters. Override any value in the environment, for example:
# DNS_NAME=buzz.example.com SSH_CIDR=203.0.113.7/32 ./scripts/provision-scaleway.sh
SERVER_NAME="${SERVER_NAME:-buzz-selfhost}"
REGION="${REGION:-nl-ams}"
ZONE="${ZONE:-${REGION}-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-PLAY2-NANO}"
IMAGE="${IMAGE:-ubuntu_noble}"
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-${SERVER_NAME}-web}"
DNS_NAME="${DNS_NAME:-}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"
DNS_TTL="${DNS_TTL:-300}"
MANAGED_TAG="buzz-selfhost:${SERVER_NAME}"

created() { printf '[created] %s\n' "$*"; }
existing() { printf '[existing] %s\n' "$*"; }
info() { printf '[info] %s\n' "$*"; }
die() { printf '[error] %s\n' "$*" >&2; exit 1; }

for command_name in scw jq; do
  command -v "${command_name}" >/dev/null 2>&1 || die "Required command not found: ${command_name}"
done

[[ -n "${DNS_NAME}" ]] || die "Set DNS_NAME to the relay FQDN, for example DNS_NAME=buzz.example.com"
[[ "${DNS_NAME}" != *://* && "${DNS_NAME}" == *.* ]] || die "DNS_NAME must be a hostname, not a URL"
[[ "${SSH_CIDR}" == */* ]] || die "SSH_CIDR must be a CIDR such as 203.0.113.7/32"
[[ "${DNS_TTL}" =~ ^[0-9]+$ ]] || die "DNS_TTL must be an integer"

# Convert list responses from both older bare-array and current wrapped JSON.
items() {
  jq -c '
    if type == "array" then .[]
    elif .servers? then .servers[]
    elif .security_groups? then .security_groups[]
    elif .rules? then .rules[]
    elif .dns_zones? then .dns_zones[]
    elif .records? then .records[]
    else empty
    end
  '
}

info "Scaleway project: $(scw config get default-project-id)"
info "Target: ${SERVER_NAME} (${INSTANCE_TYPE}, ${IMAGE}, ${ZONE})"

security_group_json="$(
  scw instance security-group list zone="${ZONE}" name="${SECURITY_GROUP_NAME}" -o json |
    items |
    jq -cs --arg name "${SECURITY_GROUP_NAME}" 'map(select(.name == $name)) | first // empty'
)"

if [[ -z "${security_group_json}" ]]; then
  security_group_json="$(scw instance security-group create \
    name="${SECURITY_GROUP_NAME}" \
    description="Buzz relay: stateful SSH, HTTP and HTTPS ingress" \
    tags.0="${MANAGED_TAG}" \
    stateful=true \
    inbound-default-policy=drop \
    outbound-default-policy=accept \
    zone="${ZONE}" \
    -o json)"
  created "security group ${SECURITY_GROUP_NAME}"
else
  jq -e --arg tag "${MANAGED_TAG}" '(.tags // []) | index($tag) != null' \
    <<<"${security_group_json}" >/dev/null ||
    die "Refusing to modify same-named security group without managed tag: ${MANAGED_TAG}"
  existing "security group ${SECURITY_GROUP_NAME}"
fi

security_group_id="$(jq -r '.id // .security_group.id // empty' <<<"${security_group_json}")"
[[ -n "${security_group_id}" ]] || die "Could not determine security-group ID"

# Reconcile safe defaults if a same-named group already existed.
if ! jq -e '
  (.stateful == true) and
  ((.inbound_default_policy // .inbound_rule.default_policy) == "drop") and
  ((.outbound_default_policy // .outbound_rule.default_policy) == "accept")
' <<<"${security_group_json}" >/dev/null; then
  scw instance security-group update "${security_group_id}" \
    stateful=true \
    inbound-default-policy=drop \
    outbound-default-policy=accept \
    zone="${ZONE}" >/dev/null
  info "updated security group defaults: stateful, inbound drop, outbound accept"
fi

rules_json="$(scw instance security-group list-rules security-group-id="${security_group_id}" zone="${ZONE}" -o json)"

# This dedicated managed group has exactly one SSH source. Remove stale SSH
# rules so changing SSH_CIDR from the initial open default actually narrows it.
while IFS= read -r stale_rule_id; do
  [[ -n "${stale_rule_id}" ]] || continue
  scw instance security-group delete-rule \
    security-group-id="${security_group_id}" \
    security-group-rule-id="${stale_rule_id}" \
    zone="${ZONE}" >/dev/null
  info "removed stale inbound TCP 22 rule"
done < <(
  items <<<"${rules_json}" | jq -r --arg cidr "${SSH_CIDR}" '
    select(
      (.protocol == "TCP") and
      (.direction == "inbound") and
      (.action == "accept") and
      ((.dest_port_from | tonumber) == 22) and
      (.ip_range != $cidr)
    ) |
    .id
  '
)
ensure_tcp_rule() {
  local port="$1"
  local cidr="$2"
  if items <<<"${rules_json}" | jq -es \
    --argjson port "${port}" \
    --arg cidr "${cidr}" '
      any(
        (.protocol == "TCP") and
        (.direction == "inbound") and
        (.action == "accept") and
        (.ip_range == $cidr) and
        ((.dest_port_from | tonumber) == $port) and
        (((.dest_port_to // .dest_port_from) | tonumber) == $port)
      )
    ' >/dev/null; then
    existing "inbound TCP ${port} from ${cidr}"
    return
  fi

  scw instance security-group create-rule security-group-id="${security_group_id}" \
    protocol=TCP \
    direction=inbound \
    action=accept \
    ip-range="${cidr}" \
    dest-port-from="${port}" \
    dest-port-to="${port}" \
    zone="${ZONE}" >/dev/null
  created "inbound TCP ${port} from ${cidr}"
}

ensure_tcp_rule 22 "${SSH_CIDR}"
ensure_tcp_rule 80 "0.0.0.0/0"
ensure_tcp_rule 443 "0.0.0.0/0"

server_json="$(
  scw instance server list zone="${ZONE}" name="${SERVER_NAME}" -o json |
    items |
    jq -cs --arg name "${SERVER_NAME}" 'map(select(.name == $name)) | first // empty'
)"

if [[ -z "${server_json}" ]]; then
  server_json="$(scw instance server create \
    name="${SERVER_NAME}" \
    type="${INSTANCE_TYPE}" \
    image="${IMAGE}" \
    ip=new \
    tags.0="${MANAGED_TAG}" \
    security-group-id="${security_group_id}" \
    zone="${ZONE}" \
    -o json)"
  created "instance ${SERVER_NAME} with a flexible public IP"
else
  jq -e --arg tag "${MANAGED_TAG}" '(.tags // []) | index($tag) != null' \
    <<<"${server_json}" >/dev/null ||
    die "Refusing to reuse same-named instance without managed tag: ${MANAGED_TAG}"
  actual_type="$(jq -r '.commercial_type // .type // empty' <<<"${server_json}")"
  if [[ -n "${actual_type}" && "${actual_type}" != "${INSTANCE_TYPE}" ]]; then
    die "Existing managed instance type is ${actual_type}, expected ${INSTANCE_TYPE}"
  fi
  existing "instance ${SERVER_NAME}"
fi

server_id="$(jq -r '.id // .server.id // empty' <<<"${server_json}")"
[[ -n "${server_id}" ]] || die "Could not determine instance ID"

current_security_group_id="$(jq -r '.security_group.id // .server.security_group.id // empty' <<<"${server_json}")"
if [[ -n "${current_security_group_id}" && "${current_security_group_id}" != "${security_group_id}" ]]; then
  scw instance server update "${server_id}" security-group-id="${security_group_id}" zone="${ZONE}" >/dev/null
  info "attached security group ${SECURITY_GROUP_NAME} to existing instance"
fi

scw instance server wait "${server_id}" zone="${ZONE}" >/dev/null
server_json="$(scw instance server get "${server_id}" zone="${ZONE}" -o json)"
public_ip="$(jq -r '
  .public_ip.address //
  .public_ips[0].address //
  .ipv4.address //
  .server.public_ip.address //
  .server.public_ips[0].address //
  empty
' <<<"${server_json}")"
[[ -n "${public_ip}" ]] || die "Instance exists but no public IPv4 address was found"
info "public IPv4: ${public_ip}"

dns_zones_json="$(scw dns zone list -o json)"
dns_zone="$(
  items <<<"${dns_zones_json}" |
    jq -rs --arg fqdn "${DNS_NAME%.}" '
      map(
        . + {
          _zone: (
            if ((.subdomain // "") | length) > 0
            then (.subdomain + "." + .domain)
            else (.dns_zone // .domain // "")
            end
          )
        }
      ) |
      map(select((._zone | length) > 0)) |
      map(select(. as $zone | ($fqdn == $zone._zone) or ($fqdn | endswith("." + $zone._zone)))) |
      sort_by(._zone | length) |
      last._zone // empty
    '
)"

if [[ -n "${dns_zone}" ]]; then
  if [[ "${DNS_NAME%.}" == "${dns_zone}" ]]; then
    record_name=""
  else
    record_name="${DNS_NAME%."${dns_zone}"}"
    record_name="${record_name%.}"
  fi

  record_json="$(scw dns record list "${dns_zone}" type=A name="${record_name}" -o json)"
  if items <<<"${record_json}" | jq -es --arg ip "${public_ip}" \
    'map(.data) | sort == ([$ip] | sort)' >/dev/null; then
    existing "DNS A ${DNS_NAME%.} -> ${public_ip}"
  else
    scw dns record set "${dns_zone}" \
      name="${record_name}" \
      type=A \
      ttl="${DNS_TTL}" \
      values.0="${public_ip}" >/dev/null
    created "DNS A ${DNS_NAME%.} -> ${public_ip}"
  fi
else
  printf '\nDNS zone for %s is not hosted in the active Scaleway project.\n' "${DNS_NAME%.}"
  printf 'Create this record manually: %s. %s IN A %s\n' "${DNS_NAME%.}" "${DNS_TTL}" "${public_ip}"
fi

printf '\nProvisioning complete.\n'
printf 'Instance ID: %s\n' "${server_id}"
printf 'Public IPv4: %s\n' "${public_ip}"
printf 'SSH: ssh root@%s\n' "${public_ip}"
printf 'Relay DNS: %s\n' "${DNS_NAME%.}"
