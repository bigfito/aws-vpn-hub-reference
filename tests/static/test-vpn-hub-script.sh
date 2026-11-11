
#!/usr/bin/env bash
# =============================================================================
# test-vpn-hub-script.sh · Pruebas de scripts/aws/vpn-hub.sh SIN tocar AWS
#
# Pone en el PATH una AWS CLI falsa que guarda cada llamada en un archivo y
# simula el estado del endpoint (asociación, ruta local y conexiones). Así se
# comprueba qué llamadas hace cada opción:
#   1. --help y opciones inválidas.
#   2. --status solo lee (ninguna operación associate/create/disassociate).
#   3. --enable --dry-run manda --dry-run en cada cambio y no cambia el estado.
#   4. --enable asocia la subnet, crea la ruta 10.81.0.0/22 -> local y espera.
#   5. --enable repetido no cambia nada (ya asociada y con ruta).
#   6. --disable sin terminal ni --yes se niega a desasociar.
#   7. --disable --yes desasocia, y --disable --dry-run no cambia nada.
#   8. Todas las llamadas del caso --enable completo usan --region mx-central-1.
#
# Uso:    tests/static/test-vpn-hub-script.sh
# Salida: "✅ OK:" o "❌ FALLA:" por caso; código 0 si todo pasa y 1 si algo
#         falla. No usa AWS ni credenciales.
# =============================================================================
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/scripts/aws/vpn-hub.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
checks=0

ok()   { checks=$((checks + 1)); echo "✅ OK: $*"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "❌ FALLA: $*"; }

# --- AWS CLI falsa ----------------------------------------------------------------
# Estado en archivos: assoc (none|associated), route (none|active), conns (0|2).
mkdir -p "$work/bin"
cat > "$work/bin/aws" <<'FAKE'
#!/usr/bin/env bash
state="$FAKE_STATE"
echo "$*" >> "$state/calls.log"
op="$1 $2"
dry=false
for arg in "$@"; do [[ "$arg" == "--dry-run" ]] && dry=true; done
assoc="$(cat "$state/assoc")"; route="$(cat "$state/route")"; conns="$(cat "$state/conns")"
dryrun_error() {
  echo "An error occurred (DryRunOperation) when calling the $1 operation: Request would have succeeded, but DryRun flag is set." >&2
  exit 254
}
case "$op" in
  "ec2 describe-client-vpn-endpoints")
    status="pending-associate"; [[ "$assoc" == "associated" ]] && status="available"
    printf 'cvpn-endpoint-0test\t%s\tvpc-0test\t10.81.0.0/22\n' "$status" ;;
  "ec2 describe-subnets") printf 'subnet-0test\n' ;;
  "ec2 describe-client-vpn-target-networks")
    if [[ "$assoc" == "associated" ]]; then printf 'cvpn-assoc-0test\tsubnet-0test\tassociated\n'; fi ;;
  "ec2 describe-client-vpn-routes")
    if [[ "$assoc" == "associated" ]]; then
      printf '10.80.0.0/16\tsubnet-0test\tactive\n'
      if [[ "$route" == "active" ]]; then printf '10.81.0.0/22\tlocal\tactive\n'; fi
    fi ;;
  "ec2 describe-client-vpn-connections")
    if [[ "$conns" != "0" ]]; then printf 'workstation-1\t10.81.0.34\nworkstation-2\t10.81.0.35\n'; fi ;;
  "route53 list-hosted-zones-by-name") printf '/hostedzone/Z0TEST\n' ;;
  "route53 list-resource-record-sets") printf 'workstation-1.vpn.example.internal.\t10.81.0.34\n' ;;
  "ec2 associate-client-vpn-target-network")
    $dry && dryrun_error AssociateClientVpnTargetNetwork
    echo associated > "$state/assoc"; printf 'cvpn-assoc-0test\tassociating\n' ;;
  "ec2 create-client-vpn-route")
    $dry && dryrun_error CreateClientVpnRoute
    echo active > "$state/route"; printf 'creating\n' ;;
  "ec2 disassociate-client-vpn-target-network")
    $dry && dryrun_error DisassociateClientVpnTargetNetwork
    echo none > "$state/assoc"; echo none > "$state/route"; printf 'cvpn-assoc-0test\tdisassociating\n' ;;
  *) echo "operación no simulada: $op" >&2; exit 1 ;;
esac
FAKE
chmod +x "$work/bin/aws"

# Prepara un estado y ejecuta el script. Uso: run_case <assoc> <route> <conns> <args...>
run_case() {
  local state="$work/state"
  rm -rf "$state"; mkdir -p "$state"
  echo "$1" > "$state/assoc"; echo "$2" > "$state/route"; echo "$3" > "$state/conns"
  : > "$state/calls.log"
  shift 3
  set +e
  output="$(PATH="$work/bin:$PATH" FAKE_STATE="$state" VPN_HUB_POLL_SECONDS=0 bash "$script" "$@" </dev/null 2>&1)"
  status=$?
  set -e
  calls="$(cat "$state/calls.log")"
  final_assoc="$(cat "$state/assoc")"; final_route="$(cat "$state/route")"
}
mutating() { grep -E '^ec2 (associate-client-vpn-target-network|create-client-vpn-route|disassociate-client-vpn-target-network)' <<<"$calls" || true; }

# 1. Ayuda y opciones inválidas.
run_case none none 0 --help
if (( status == 0 )) && grep -q -- "--enable" <<<"$output" && grep -q -- "--dry-run" <<<"$output"; then ok "--help describe las opciones"; else fail "--help (código $status)"; fi
run_case none none 0
if (( status == 2 )); then ok "sin opciones: código 2"; else fail "sin opciones: código $status"; fi
run_case none none 0 --enable --disable
if (( status == 2 )); then ok "--enable y --disable juntos: código 2"; else fail "--enable --disable: código $status"; fi
run_case none none 0 --status --dry-run
if (( status == 2 )); then ok "--status --dry-run: código 2"; else fail "--status --dry-run: código $status"; fi

# 2. --status solo lee.
run_case associated active 2 --status
if (( status == 0 )) && [[ -z "$(mutating)" ]] && grep -q "10.81.0.0/22 → local" <<<"$output" && grep -q "workstation-1 (10.81.0.34)" <<<"$output"; then
  ok "--status solo lee y muestra rutas y conexiones"
else
  fail "--status (código $status): $(mutating)"
fi

# 3. --enable --dry-run: cada cambio lleva --dry-run y el estado no cambia.
run_case none none 0 --enable --dry-run
dry_calls="$(mutating)"
if (( status == 0 )) && [[ -n "$dry_calls" ]] && ! grep -qv -- "--dry-run" <<<"$dry_calls" && [[ "$final_assoc" == "none" && "$final_route" == "none" ]]; then
  ok "--enable --dry-run: $(wc -l <<<"$dry_calls") cambio(s), todos con --dry-run; nada cambió"
else
  fail "--enable --dry-run (código $status, asociación $final_assoc): $dry_calls"
fi

# 4. --enable desde apagado: asocia, crea la ruta local y termina con todo activo.
run_case none none 0 --enable
if (( status == 0 )) && grep -q "associate-client-vpn-target-network --client-vpn-endpoint-id cvpn-endpoint-0test --subnet-id subnet-0test" <<<"$calls" &&
   grep -q "create-client-vpn-route .*--destination-cidr-block 10.81.0.0/22 --target-vpc-subnet-id local" <<<"$calls" &&
   [[ "$final_assoc" == "associated" && "$final_route" == "active" ]]; then
  ok "--enable asocia la subnet y crea la ruta 10.81.0.0/22 -> local"
else
  fail "--enable (código $status): $(mutating) | salida: $(tail -3 <<<"$output")"
fi

# 5. --enable con todo encendido no cambia nada.
run_case associated active 0 --enable
if (( status == 0 )) && [[ -z "$(mutating)" ]]; then ok "--enable repetido no hace cambios"; else fail "--enable repetido: $(mutating)"; fi

# 6. --disable sin terminal ni --yes no desasocia.
run_case associated active 2 --disable
if (( status != 0 )) && [[ -z "$(mutating)" && "$final_assoc" == "associated" ]]; then
  ok "--disable sin confirmación se niega (código $status) y avisa de 2 conexiones: $(grep -c ' - ' <<<"$output")"
else
  fail "--disable sin --yes (código $status): $(mutating)"
fi

# 7. --disable --yes desasocia.
run_case associated active 2 --disable --yes
if (( status == 0 )) && grep -q "disassociate-client-vpn-target-network --client-vpn-endpoint-id cvpn-endpoint-0test --association-id cvpn-assoc-0test" <<<"$calls" && [[ "$final_assoc" == "none" ]]; then
  ok "--disable --yes desasocia"
else
  fail "--disable --yes (código $status): $(mutating)"
fi

# 7b. --disable --dry-run no cambia nada.
run_case associated active 0 --disable --dry-run
if (( status == 0 )) && [[ "$final_assoc" == "associated" ]] && ! grep -qv -- "--dry-run" <<<"$(mutating)"; then ok "--disable --dry-run no cambia nada"; else fail "--disable --dry-run (código $status)"; fi

# 8. Región explícita en todas las llamadas del último caso completo (--enable).
run_case none none 0 --enable
if [[ -n "$calls" ]] && ! grep -qv -- "--region mx-central-1" <<<"$calls"; then
  ok "las $(wc -l <<<"$calls") llamadas usan --region mx-central-1"
else
  fail "hay llamadas sin --region mx-central-1"
fi

if (( failures > 0 )); then
  echo "Resultado: FALLA — $failures de $checks caso(s) con error."
  exit 1
fi
echo "Resultado: PASA — $checks caso(s) correctos."

