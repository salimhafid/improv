#!/usr/bin/env bash
#
# Deploy the UCB NY shows scraper + viewer to Google Cloud.
#   - Cloud Run service (scrapes + serves)
#   - GCS bucket (durable last-good cache)
#   - Cloud Scheduler job (hourly POST /refresh)
#
# Idempotent: safe to re-run. The refresh token is generated once and stored in
# .refresh_token.local (gitignored) so redeploys keep Scheduler + service in sync.
#
# Usage: bash deploy.sh
set -euo pipefail

PROJECT="${PROJECT:-storage-dashboards}"
REGION="${REGION:-us-central1}"
SERVICE="${SERVICE:-ucb-ny-shows}"
BUCKET="${BUCKET:-${PROJECT}-ucb-ny-shows}"
SA_NAME="${SA_NAME:-ucb-scraper}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
JOB="${JOB:-ucb-hourly}"
TOKEN_FILE=".refresh_token.local"

echo "==> Project=${PROJECT} Region=${REGION} Service=${SERVICE} Bucket=${BUCKET}"
gcloud config set project "${PROJECT}" >/dev/null

echo "==> Enabling APIs (idempotent)…"
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  cloudscheduler.googleapis.com \
  storage.googleapis.com

echo "==> Ensuring GCS bucket gs://${BUCKET}…"
if ! gcloud storage buckets describe "gs://${BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${BUCKET}" \
    --location="${REGION}" --uniform-bucket-level-access
else
  echo "    bucket already exists."
fi

echo "==> Ensuring service account ${SA_EMAIL}…"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="UCB NY shows scraper"
else
  echo "    service account already exists."
fi

echo "==> Granting bucket access to ${SA_EMAIL}…"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin" >/dev/null

echo "==> Refresh token…"
if [[ -f "${TOKEN_FILE}" ]]; then
  REFRESH_TOKEN="$(cat "${TOKEN_FILE}")"
  echo "    reusing existing ${TOKEN_FILE}"
else
  REFRESH_TOKEN="$(openssl rand -hex 24)"
  printf '%s' "${REFRESH_TOKEN}" > "${TOKEN_FILE}"
  echo "    generated new token -> ${TOKEN_FILE}"
fi

echo "==> Deploying Cloud Run service (builds container from source)…"
gcloud run deploy "${SERVICE}" \
  --source . \
  --region="${REGION}" \
  --service-account="${SA_EMAIL}" \
  --allow-unauthenticated \
  --memory=512Mi \
  --cpu=1 \
  --timeout=180 \
  --min-instances=0 \
  --max-instances=3 \
  --set-env-vars="BUCKET=${BUCKET},REFRESH_TOKEN=${REFRESH_TOKEN}"

URL="$(gcloud run services describe "${SERVICE}" --region="${REGION}" --format='value(status.url)')"
echo "==> Service URL: ${URL}"

echo "==> Ensuring public access (allUsers run.invoker)…"
if gcloud run services add-iam-policy-binding "${SERVICE}" --region="${REGION}" \
     --member="allUsers" --role="roles/run.invoker" >/dev/null 2>&1; then
  echo "    public access granted."
  PUBLIC=1
else
  echo "    WARNING: could not grant public access (likely org policy). Service is authenticated-only."
  PUBLIC=0
fi

# Scheduler must be able to invoke /refresh even if the service is private.
gcloud run services add-iam-policy-binding "${SERVICE}" --region="${REGION}" \
  --member="serviceAccount:${SA_EMAIL}" --role="roles/run.invoker" >/dev/null 2>&1 || true

echo "==> Configuring hourly Cloud Scheduler job '${JOB}'…"
SCHED_ARGS=(
  --location="${REGION}"
  --schedule="0 * * * *"
  --time-zone="America/New_York"
  --uri="${URL}/refresh"
  --http-method=POST
  --oidc-service-account-email="${SA_EMAIL}"
  --oidc-token-audience="${URL}"
  --attempt-deadline=180s
)
# `create http` uses --headers; `update http` uses --update-headers for the same effect.
if gcloud scheduler jobs describe "${JOB}" --location="${REGION}" >/dev/null 2>&1; then
  gcloud scheduler jobs update http "${JOB}" "${SCHED_ARGS[@]}" \
    --update-headers="X-Refresh-Token=${REFRESH_TOKEN}"
else
  gcloud scheduler jobs create http "${JOB}" "${SCHED_ARGS[@]}" \
    --headers="X-Refresh-Token=${REFRESH_TOKEN}"
fi

echo "==> Priming data with one immediate refresh…"
gcloud scheduler jobs run "${JOB}" --location="${REGION}" || true
sleep 8

echo ""
echo "============================================================"
echo " Deployed."
echo "   Page:      ${URL}/"
echo "   JSON:      ${URL}/shows.json"
echo "   Refresh:   hourly via Cloud Scheduler job '${JOB}'"
if [[ "${PUBLIC}" == "1" ]]; then
  echo "   Access:    PUBLIC"
else
  echo "   Access:    AUTHENTICATED ONLY (org policy blocked public access)"
fi
echo "============================================================"
