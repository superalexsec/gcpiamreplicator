#!/usr/bin/env bash
set -Eeuo pipefail

# ========================
# EDIT THESE TWO
# ========================
PROD_PROJECT="PROJECT_ID_1"
HML_PROJECT="PROJECT_ID_2"

# Dry-run by default; pass --apply to execute changes.
APPLY="false"
if [[ "${1:-}" == "--apply" ]]; then
  APPLY="true"
fi

echo "==> Prod: ${PROD_PROJECT} | Homolog: ${HML_PROJECT} | APPLY=${APPLY}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Missing required command: $1" >&2; exit 1; }; }
need gcloud
need jq

# Verify projects are reachable (warn but don't exit hard; we'll fall back to empty files if needed)
if ! gcloud config list --quiet >/dev/null 2>&1; then
  echo "WARN: gcloud not authenticated; proceeding with empty fallbacks." >&2
fi
if ! gcloud projects describe "${PROD_PROJECT}" >/dev/null 2>&1; then
  echo "WARN: Cannot access project ${PROD_PROJECT}; will write empty fallbacks." >&2
fi
if ! gcloud projects describe "${HML_PROJECT}" >/dev/null 2>&1; then
  echo "WARN: Cannot access project ${HML_PROJECT}; will write empty fallbacks." >&2
fi

WORKDIR="$(mktemp -d -t replicate_sa_iam_XXXXXX)"
echo "==> Working in ${WORKDIR}"
trap 'echo "Temp files in: ${WORKDIR}"' EXIT

# --- helpers that NEVER leave missing files ---
capture_json() { # cmd_string outfile fallback_json
  local cmd="$1" outfile="$2" fallback="$3"
  local tmp="${outfile}.tmp"
  if eval "$cmd" >"$tmp" 2>"${outfile}.err"; then
    :
  else
    echo "WARN: Command failed; writing fallback for $(basename "$outfile"): $cmd" >&2
  fi
  if [[ ! -s "$tmp" ]]; then
    printf '%s\n' "$fallback" >"$outfile"
  else
    mv "$tmp" "$outfile"
  fi
}

capture_list() { # cmd_string outfile
  local cmd="$1" outfile="$2"
  local tmp="${outfile}.tmp"
  if eval "$cmd" >"$tmp" 2>"${outfile}.err"; then
    :
  else
    echo "WARN: Command failed; writing empty list for $(basename "$outfile"): $cmd" >&2
  fi
  if [[ ! -s "$tmp" ]]; then
    : >"$outfile"  # create empty file
  else
    mv "$tmp" "$outfile"
  fi
}

# ------------------------------------------------------------
# 1) Export Prod service accounts & IAM (with guaranteed files)
# ------------------------------------------------------------
echo "==> Exporting Prod service accounts and project IAM policy..."

PROD_SA_JSON="${WORKDIR}/prod-service-accounts.json"
PROD_IAM_JSON="${WORKDIR}/prod-project-iam-policy.json"

capture_json \
  "gcloud iam service-accounts list --project='${PROD_PROJECT}' --format=json" \
  "${PROD_SA_JSON}" \
  '[]'

capture_json \
  "gcloud projects get-iam-policy '${PROD_PROJECT}' --format=json" \
  "${PROD_IAM_JSON}" \
  '{"bindings": []}'

# ------------------------------------------------------------
# 2) Create Homolog SAs (always with -hml suffix)
# ------------------------------------------------------------
echo '==> Ensuring Homolog service accounts exist (with -hml suffix)...'
HML_EXISTING_SAS="${WORKDIR}/hml-existing-service-accounts.txt"

capture_list \
  "gcloud iam service-accounts list --project='${HML_PROJECT}' --format='value(email)'" \
  "${HML_EXISTING_SAS}"

# Iterate even if empty JSON — loop simply won't run
jq -r '.[] | [.email, (.displayName // ""), (.description // "")] | @tsv' "${PROD_SA_JSON}" \
| while IFS=$'\t' read -r PROD_EMAIL DISPLAY DESC; do
  [[ -n "${PROD_EMAIL}" ]] || continue
  PROD_NAME="$(cut -d'@' -f1 <<<"${PROD_EMAIL}")"
  BASE_NAME="${PROD_NAME##serviceAccount:}"       # tolerate accidental "serviceAccount:" prefix
  HML_NAME="${BASE_NAME}-hml"
  HML_EMAIL="${HML_NAME}@${HML_PROJECT}.iam.gserviceaccount.com"

  if grep -qx "${HML_EMAIL}" "${HML_EXISTING_SAS}"; then
    echo "   - SA exists in HML: ${HML_EMAIL}"
  else
    echo "   - Creating SA in HML: ${HML_EMAIL}"
    if [[ "${APPLY}" == "true" ]]; then
      # Best-effort create; if it fails we continue
      if ! gcloud iam service-accounts create "${HML_NAME}" \
            --project="${HML_PROJECT}" \
            --display-name="${DISPLAY:-${HML_NAME}}" \
            --description="$(printf "%s%s" "${DESC:-"Cloned from ${BASE_NAME}"}" " (HML clone)")" >/dev/null 2>&1; then
        echo "WARN: Could not create ${HML_EMAIL} (continuing)" >&2
      fi
    fi
  fi
done

# ------------------------------------------------------------
# 3) Replicate project-level IAM bindings to HML for -hml SAs
# ------------------------------------------------------------
echo "==> Replicating project-level IAM bindings (skipping roles/owner) to HML -hml SAs..."

PLAN_FILE="${WORKDIR}/project-sa-bindings-plan.txt"
: > "${PLAN_FILE}"

# Build plan even if bindings are empty (file remains empty)
jq -r --arg prod "${PROD_PROJECT}" '
  (.bindings // [])
  | .[]
  | select(.role != "roles/owner")
  | .role as $role
  | (.members // [])
  | map(select(startswith("serviceAccount:")))
  | .[]
  | select(endswith("@" + $prod + ".iam.gserviceaccount.com"))
  | [$role, .]
  | @tsv
' "${PROD_IAM_JSON}" \
| while IFS=$'\t' read -r ROLE MEMBER; do
    PROD_EMAIL="${MEMBER#serviceAccount:}"
    BASE_NAME="$(cut -d'@' -f1 <<<"${PROD_EMAIL}")"
    HML_NAME="${BASE_NAME}-hml"
    HML_EMAIL="${HML_NAME}@${HML_PROJECT}.iam.gserviceaccount.com"
    echo -e "${ROLE}\tserviceAccount:${HML_EMAIL}" >> "${PLAN_FILE}"
done

if [[ -s "${PLAN_FILE}" ]]; then
  sort -u "${PLAN_FILE}" -o "${PLAN_FILE}"
  while IFS=$'\t' read -r ROLE MEMBER; do
    echo "   - Bind ${MEMBER} -> ${ROLE} (project ${HML_PROJECT})"
    if [[ "${APPLY}" == "true" ]]; then
      if ! gcloud projects add-iam-policy-binding "${HML_PROJECT}" \
            --member="${MEMBER}" --role="${ROLE}" >/dev/null 2>&1; then
        echo "WARN: Failed to bind ${MEMBER} to ${ROLE} (continuing)" >&2
      fi
    fi
  done < "${PLAN_FILE}"
else
  echo "   - No service-account-based bindings found to replicate (plan is empty)."
fi

echo "==> Completed. Temp outputs in: ${WORKDIR}"
echo "Review above actions. Re-run with --apply to execute changes if you haven’t already."

