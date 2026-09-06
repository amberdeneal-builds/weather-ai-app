"""Weather AI Lambda - real weather lookup + Bedrock/Vertex AI insight.

Given a latitude/longitude, fetches current conditions and today's forecast
from the National Weather Service (api.weather.gov - free, no API key), asks
Bedrock (Claude Haiku 4.5, via its US inference profile) for a short human-
readable insight, and caches the combined result in DynamoDB for
CACHE_TTL_SECONDS.

If Bedrock is unavailable, get_ai_insight() fails over to GCP Vertex AI
(Gemini) using a service-account credential stored in Secrets Manager - see
_invoke_vertex(). Only if *both* providers fail does a request surface as a
502.
"""

import json
import os
import time
import urllib.error
import urllib.request
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError
from google.auth.transport.requests import Request as GoogleAuthRequest
from google.oauth2 import service_account

TABLE_NAME = os.environ["TABLE_NAME"]
BEDROCK_MODEL_ID = os.environ["BEDROCK_MODEL_ID"]
CACHE_TTL_SECONDS = int(os.environ.get("CACHE_TTL_SECONDS", "600"))
NWS_USER_AGENT = os.environ.get(
    "NWS_USER_AGENT", "weather-ai-app (https://github.com/amberdeneal-builds/weather-ai-app)"
)

# GCP Vertex AI failover - used by get_ai_insight() only when Bedrock fails.
GCP_PROJECT_ID = os.environ.get("GCP_PROJECT_ID")
GCP_VERTEX_LOCATION = os.environ.get("GCP_VERTEX_LOCATION", "us-central1")
GCP_VERTEX_MODEL_ID = os.environ.get("GCP_VERTEX_MODEL_ID", "gemini-2.5-flash")
GCP_VERTEX_SECRET_NAME = os.environ.get("GCP_VERTEX_SECRET_NAME", "weather-ai/gcp-vertex-failover-key")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(TABLE_NAME)
bedrock = boto3.client("bedrock-runtime")
secrets_client = boto3.client("secretsmanager")

# Cached across warm Lambda invocations so a GCP service-account credential
# (and its signed access token) isn't re-fetched/re-signed on every request -
# only refreshed once it actually expires. None until the first Vertex call.
_gcp_credentials = None


class UpstreamError(Exception):
    """NWS or Bedrock failed in a way the caller should see as a 502, not a 500."""


def _to_dynamodb_safe(value):
    """DynamoDB's boto3 resource layer rejects native Python floats outright
    ("Float types are not supported. Use Decimal types instead.") - NWS's
    JSON response parses numbers like temperature into plain floats, so
    everything written to the table has to be walked and converted first.
    str(value) avoids binary float imprecision (Decimal(0.1) != Decimal("0.1"))."""
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _to_dynamodb_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_dynamodb_safe(v) for v in value]
    return value


def _from_dynamodb_safe(value):
    """The inverse conversion for cache hits read back from DynamoDB: Decimal
    -> int or float, so the JSON response has real numbers instead of the
    stringified Decimals json.dumps(..., default=str) would otherwise produce."""
    if isinstance(value, Decimal):
        return int(value) if value % 1 == 0 else float(value)
    if isinstance(value, dict):
        return {k: _from_dynamodb_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_from_dynamodb_safe(v) for v in value]
    return value


def _nws_get(url):
    req = urllib.request.Request(
        url,
        headers={"User-Agent": NWS_USER_AGENT, "Accept": "application/geo+json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise UpstreamError(f"NWS request failed ({e.code}) for {url}") from e
    except urllib.error.URLError as e:
        raise UpstreamError(f"NWS request failed ({e.reason}) for {url}") from e


def get_current_conditions(lat, lon):
    """NWS is a multi-step API: lat/lon -> grid point -> nearest station's
    latest observation, plus a separate forecast lookup for today's outlook."""
    points = _nws_get(f"https://api.weather.gov/points/{lat},{lon}")
    props = points["properties"]

    stations = _nws_get(props["observationStations"])
    features = stations.get("features") or []
    if not features:
        raise UpstreamError(f"NWS returned no observation stations for {lat},{lon}")
    station_id = features[0]["properties"]["stationIdentifier"]

    latest = _nws_get(f"https://api.weather.gov/stations/{station_id}/observations/latest")
    obs = latest["properties"]

    forecast = _nws_get(props["forecast"])
    periods = (forecast.get("properties") or {}).get("periods") or []
    today = periods[0] if periods else {}

    def _value(field):
        return (obs.get(field) or {}).get("value")

    return {
        "station": station_id,
        "temperature_c": _value("temperature"),
        "relative_humidity_pct": _value("relativeHumidity"),
        "wind_speed_kmh": _value("windSpeed"),
        "barometric_pressure_pa": _value("barometricPressure"),
        "text_description": obs.get("textDescription"),
        "forecast_short": today.get("shortForecast"),
        "forecast_detailed": today.get("detailedForecast"),
    }


def _get_gcp_access_token():
    """Fetch (once) and refresh (as needed) the GCP service-account credential
    used for Vertex AI. Reads the key JSON from Secrets Manager the first time
    a Vertex call is actually needed - never on the Bedrock-succeeds happy path."""
    global _gcp_credentials
    if _gcp_credentials is None:
        secret = secrets_client.get_secret_value(SecretId=GCP_VERTEX_SECRET_NAME)
        sa_info = json.loads(secret["SecretString"])
        _gcp_credentials = service_account.Credentials.from_service_account_info(
            sa_info, scopes=["https://www.googleapis.com/auth/cloud-platform"]
        )
    if not _gcp_credentials.valid:
        _gcp_credentials.refresh(GoogleAuthRequest())
    return _gcp_credentials.token


def _invoke_vertex(prompt):
    """GCP Vertex AI (Gemini) failover for get_ai_insight() - only called when
    Bedrock itself fails. Any failure here (bad secret, auth, network, an
    unexpected response shape) is surfaced as UpstreamError so the caller can
    report "both providers failed" instead of a raw traceback."""
    try:
        token = _get_gcp_access_token()
        url = (
            f"https://{GCP_VERTEX_LOCATION}-aiplatform.googleapis.com/v1/projects/"
            f"{GCP_PROJECT_ID}/locations/{GCP_VERTEX_LOCATION}/publishers/google/models/"
            f"{GCP_VERTEX_MODEL_ID}:generateContent"
        )
        body = json.dumps({"contents": [{"role": "user", "parts": [{"text": prompt}]}]}).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            payload = json.loads(resp.read())
        return payload["candidates"][0]["content"]["parts"][0]["text"].strip()
    except Exception as e:
        raise UpstreamError(f"Vertex AI invoke failed: {e}") from e


def get_ai_insight(conditions, city_label):
    """Bedrock is the primary AI-insight provider; GCP Vertex AI (Gemini) is
    the cross-cloud failover if Bedrock is unavailable for any reason."""
    prompt = (
        f"Current weather for {city_label}: {json.dumps(conditions)}. "
        "In 2-3 friendly sentences, tell the user what to expect today and "
        "one practical thing to plan around (clothing, travel, outdoor plans). "
        "No preamble, no markdown."
    )
    bedrock_body = json.dumps(
        {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 200,
            "messages": [{"role": "user", "content": prompt}],
        }
    )
    try:
        response = bedrock.invoke_model(modelId=BEDROCK_MODEL_ID, body=bedrock_body)
        payload = json.loads(response["body"].read())
        print("ai_insight served by: bedrock")
        return payload["content"][0]["text"].strip()
    except ClientError as bedrock_error:
        print(f"ai_insight: bedrock failed ({bedrock_error}); trying vertex failover")
        try:
            result = _invoke_vertex(prompt)
            print("ai_insight served by: vertex (bedrock failover)")
            return result
        except UpstreamError as vertex_error:
            raise UpstreamError(
                f"Bedrock invoke failed ({bedrock_error}); Vertex AI failover also failed ({vertex_error})"
            ) from vertex_error


def lambda_handler(event, context):
    params = (event or {}).get("queryStringParameters") or {}
    try:
        lat = float(params["lat"])
        lon = float(params["lon"])
    except (KeyError, TypeError, ValueError):
        return _response(400, {"error": "lat and lon query parameters are required (decimal degrees)"})

    city_label = params.get("city", f"{lat},{lon}")
    cache_key = f"weather#{lat:.2f},{lon:.2f}"
    now = int(time.time())

    cached = table.get_item(Key={"cache_key": cache_key}).get("Item")
    if cached and cached.get("expires_at", 0) > now:
        return _response(200, _to_body(_from_dynamodb_safe(cached), from_cache=True))

    try:
        conditions = get_current_conditions(lat, lon)
        insight = get_ai_insight(conditions, city_label)
    except UpstreamError as e:
        return _response(502, {"error": str(e)})

    item = {
        "cache_key": cache_key,
        "city": city_label,
        "conditions": conditions,
        "ai_insight": insight,
        "checked_at": now,
        "expires_at": now + CACHE_TTL_SECONDS,
    }
    table.put_item(Item=_to_dynamodb_safe(item))

    return _response(200, _to_body(item, from_cache=False))


def _to_body(item, from_cache):
    return {
        "city": item["city"],
        "conditions": item["conditions"],
        "ai_insight": item["ai_insight"],
        "checked_at": item["checked_at"],
        "from_cache": from_cache,
    }


def _response(status_code, payload):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, default=str),
    }
