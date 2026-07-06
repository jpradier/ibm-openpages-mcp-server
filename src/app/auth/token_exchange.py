"""
Token Exchange Module

Standalone async functions for exchanging credentials for tokens
across IBM Cloud IAM, MCSP, and CP4D authentication services.
Also supports cookie-based session authentication for WebSEAL-fronted
OpenPages instances where the session cookies are obtained via a browser
SSO flow and supplied directly.
"""

import logging
from typing import Dict, Optional

import httpx  # type: ignore

logger = logging.getLogger(__name__)


def detect_auth_type(authentication_url: str) -> str:
    """
    Detect authentication type based on the authentication URL.

    Args:
        authentication_url: The authentication URL.  Pass an empty string or
            ``"cookie"`` to select cookie-based session auth (no token exchange
            required).

    Returns:
        One of 'ibm_cloud', 'mcsp', 'cp4d', 'oidc', or 'cookie'
    """
    if not authentication_url or authentication_url.strip().lower() == "cookie":
        logger.info("Detected cookie-based session authentication")
        return 'cookie'
    if '/icp4d-api/v1/authorize' in authentication_url in authentication_url:
        logger.info("Detected CP4D authentication")
        return 'cp4d'
    elif 'iam.cloud.ibm.com' in authentication_url or 'iam.test.cloud.ibm.com' in authentication_url:
        logger.info("Detected IBM Cloud OAuth2 authentication")
        return 'ibm_cloud'
    elif 'account-iam.platform' in authentication_url or 'saas.ibm.com' in authentication_url:
        logger.info("Detected MCSP OAuth2 authentication")
        return 'mcsp'
    elif '/protocol/openid-connect/token' in authentication_url or '/oauth2/token' in authentication_url:
        logger.info("Detected generic OIDC authentication (Keycloak / OAuth2 password/client-credentials grant)")
        return 'oidc'
    else:
        logger.warning(f"Could not detect auth type from URL: {authentication_url}. Defaulting to IBM Cloud.")
        return 'ibm_cloud'


async def fetch_ibm_cloud_token(api_key: str, auth_url: str) -> str:
    """
    Exchange API key for IBM Cloud IAM token.

    Args:
        api_key: IBM Cloud API key
        auth_url: IBM Cloud IAM token endpoint

    Returns:
        Access token string

    Raises:
        RuntimeError: If token exchange fails
    """
    headers = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json'
    }
    data = {
        'grant_type': 'urn:ibm:params:oauth:grant-type:apikey',
        'apikey': api_key
    }

    try:
        async with httpx.AsyncClient(verify=True) as client:
            logger.info(f"Fetching IBM Cloud token from {auth_url}")
            response = await client.post(auth_url, headers=headers, data=data, timeout=30.0)
            response.raise_for_status()
            token_data = response.json()

            if 'access_token' in token_data:
                logger.info("Successfully obtained IBM Cloud access token")
                return token_data['access_token']
            else:
                raise RuntimeError("'access_token' not found in IBM Cloud response")

    except httpx.HTTPStatusError as e:
        logger.error(f"Error fetching IBM Cloud token: {e}")
        raise RuntimeError(f"IBM Cloud token exchange failed ({e.response.status_code}): {e.response.text}") from e
    except httpx.RequestError as e:
        logger.error(f"Request error fetching IBM Cloud token: {e}")
        raise RuntimeError(f"Network error during IBM Cloud token exchange: {e}") from e


async def fetch_mcsp_token(api_key: str, auth_url: str) -> str:
    """
    Exchange API key for MCSP token.

    Args:
        api_key: MCSP API key
        auth_url: MCSP token endpoint

    Returns:
        Access token string

    Raises:
        RuntimeError: If token exchange fails
    """
    headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
    }
    json_data = {
        'apikey': api_key
    }

    try:
        async with httpx.AsyncClient(verify=True) as client:
            logger.info(f"Fetching MCSP token from {auth_url}")
            response = await client.post(auth_url, headers=headers, json=json_data, timeout=30.0)
            response.raise_for_status()
            token_data = response.json()

            if 'token' in token_data:
                logger.info("Successfully obtained MCSP token")
                return token_data['token']
            else:
                raise RuntimeError("'token' not found in MCSP response")

    except httpx.HTTPStatusError as e:
        logger.error(f"Error fetching MCSP token: {e}")
        raise RuntimeError(f"MCSP token exchange failed ({e.response.status_code}): {e.response.text}") from e
    except httpx.RequestError as e:
        logger.error(f"Request error fetching MCSP token: {e}")
        raise RuntimeError(f"Network error during MCSP token exchange: {e}") from e


async def fetch_cp4d_token(username: str, password: str, auth_url: str, ssl_verify: bool = True) -> str:
    """
    Exchange credentials for CP4D token.

    Args:
        username: CP4D username
        password: CP4D password
        auth_url: CP4D authorization endpoint
        ssl_verify: Whether to verify SSL certificates

    Returns:
        Access token string

    Raises:
        RuntimeError: If token exchange fails
    """
    headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json'
    }
    json_data = {
        'username': username,
        'password': password
    }

    try:
        async with httpx.AsyncClient(verify=ssl_verify) as client:
            logger.info(f"Fetching CP4D token from {auth_url}")
            if not ssl_verify:
                logger.warning("SSL verification is disabled for CP4D authentication")
            response = await client.post(auth_url, headers=headers, json=json_data, timeout=30.0)
            response.raise_for_status()
            token_data = response.json()

            if 'token' in token_data:
                logger.info("Successfully obtained CP4D token")
                return token_data['token']
            else:
                raise RuntimeError("'token' not found in CP4D response")

    except httpx.HTTPStatusError as e:
        logger.error(f"Error fetching CP4D token: {e}")
        raise RuntimeError(f"CP4D token exchange failed ({e.response.status_code}): {e.response.text}") from e
    except httpx.RequestError as e:
        logger.error(f"Request error fetching CP4D token: {e}")
        raise RuntimeError(f"Network error during CP4D token exchange: {e}") from e


async def fetch_oidc_token(
    auth_url: str,
    username: Optional[str] = None,
    password: Optional[str] = None,
    api_key: Optional[str] = None,
    client_id: Optional[str] = None,
    client_secret: Optional[str] = None,
    ssl_verify: bool = True,
) -> str:
    """
    Fetch a token from a generic OIDC / Keycloak endpoint.

    Supports two grant types depending on the credentials provided:
    - ``password`` grant  – when ``username`` and ``password`` are set
      (used by WebSEAL-fronted OpenPages with a Keycloak IdP, e.g. DPD/Geopost)
    - ``client_credentials`` grant – when only ``client_id`` and ``client_secret``
      are set (no user context)
    - ``apikey`` grant fallback – when only ``api_key`` is set
      (non-standard, kept for backwards-compat with some OIDC proxies)

    The token URL is the value of ``OPENPAGES_AUTHENTICATION_URL`` and must
    end with ``/protocol/openid-connect/token`` (Keycloak) or ``/oauth2/token``.

    Required .env variables for the password grant::

        OPENPAGES_AUTHENTICATION_URL=https://sso.example.com/auth/realms/REALM/protocol/openid-connect/token
        OPENPAGES_USERNAME=your_username
        OPENPAGES_PASSWORD=your_password
        # client_id / client_secret are optional; some Keycloak realms allow public clients
        # OPENPAGES_OIDC_CLIENT_ID=my_client
        # OPENPAGES_OIDC_CLIENT_SECRET=my_secret

    Args:
        auth_url: Full OIDC token endpoint URL
        username: User login (password grant)
        password: User password (password grant)
        api_key: API key (fallback for custom OIDC proxies)
        client_id: OAuth2 client_id (optional for password grant, required for client_credentials)
        client_secret: OAuth2 client_secret (optional)
        ssl_verify: Whether to verify SSL certificates

    Returns:
        Access token string

    Raises:
        RuntimeError: If token exchange fails or no credentials are provided
    """
    if not username and not password and not api_key and not (client_id and client_secret):
        raise RuntimeError(
            "OIDC token fetch requires credentials. "
            "Set OPENPAGES_USERNAME + OPENPAGES_PASSWORD (password grant), "
            "or OPENPAGES_OIDC_CLIENT_ID + OPENPAGES_OIDC_CLIENT_SECRET (client_credentials grant)."
        )

    headers = {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Accept': 'application/json',
    }

    if username and password:
        # Resource Owner Password Credentials (ROPC) grant
        data: dict = {
            'grant_type': 'password',
            'username': username,
            'password': password,
        }
        if client_id:
            data['client_id'] = client_id
        if client_secret:
            data['client_secret'] = client_secret
        logger.info(f"Fetching OIDC token (password grant) from {auth_url} for user '{username}'")
    elif client_id and client_secret:
        # Client Credentials grant
        data = {
            'grant_type': 'client_credentials',
            'client_id': client_id,
            'client_secret': client_secret,
        }
        logger.info(f"Fetching OIDC token (client_credentials grant) from {auth_url}")
    else:
        # Fallback: apikey grant (non-standard OIDC proxy)
        data = {
            'grant_type': 'urn:ibm:params:oauth:grant-type:apikey',
            'apikey': api_key,
        }
        logger.info(f"Fetching OIDC token (apikey grant) from {auth_url}")

    try:
        async with httpx.AsyncClient(verify=ssl_verify) as client:
            response = await client.post(auth_url, headers=headers, data=data, timeout=30.0)
            response.raise_for_status()
            token_data = response.json()

        for key in ('access_token', 'token', 'id_token'):
            if key in token_data:
                logger.info(f"Successfully obtained OIDC token (field: '{key}')")
                return token_data[key]

        raise RuntimeError(
            f"No recognised token field in OIDC response. Keys present: {list(token_data.keys())}"
        )

    except httpx.HTTPStatusError as e:
        logger.error(f"Error fetching OIDC token: {e}")
        raise RuntimeError(
            f"OIDC token exchange failed ({e.response.status_code}): {e.response.text}"
        ) from e
    except httpx.RequestError as e:
        logger.error(f"Request error fetching OIDC token: {e}")
        raise RuntimeError(f"Network error during OIDC token exchange: {e}") from e


def parse_cookie_string(cookie_string: str) -> Dict[str, str]:
    """
    Parse a browser-style ``Cookie:`` header value into a name→value dict.

    Accepts the raw string you copy from browser DevTools, e.g.::

        "OPJSESSIONID=abc123; OPToken=xyz; OP-XSRF-TOKEN=tok"

    Non-ASCII characters (e.g. Unicode ellipsis ``…`` from copy-paste truncation)
    are stripped from cookie values so the resulting ``Cookie:`` header is valid ASCII.
    A warning is logged for every cookie whose value had to be sanitised.

    Args:
        cookie_string: Raw ``Cookie`` header value

    Returns:
        Dict mapping cookie name to value (empty dict if input is empty)
    """
    if not cookie_string or not cookie_string.strip():
        return {}
    cookies: Dict[str, str] = {}
    for part in cookie_string.split(";"):
        part = part.strip()
        if not part:
            continue
        if "=" in part:
            name, _, value = part.partition("=")
            name = name.strip()
            value = value.strip()
            # HTTP headers must be ASCII — strip any non-ASCII characters that
            # may have been introduced by copy-paste truncation (e.g. U+2026 '…')
            ascii_value = value.encode("ascii", errors="ignore").decode("ascii")
            if ascii_value != value:
                logger.warning(
                    f"Cookie '{name}' contained non-ASCII characters that were stripped. "
                    "This usually means the cookie value was truncated during copy-paste "
                    "(e.g. a '…' ellipsis was inserted). "
                    "Copy the Cookie header again from DevTools without truncation."
                )
            cookies[name] = ascii_value
        else:
            cookies[part.strip()] = ""
    return cookies


async def fetch_openpages_session_cookies(
    base_url: str,
    username: str,
    password: str,
    ssl_verify: bool = True,
) -> Dict[str, str]:
    """
    Perform the OpenPages FORM-based login flow and return session cookies.

    The flow (discovered from the /logon.jsp page):
    1. GET  ``<base_url>/logon.jsp``       → harvest initial cookies
    2. POST ``<base_url>/j_security_check`` → authenticate and receive ``OPLtpaToken2``

    For instances configured to authorize REST API calls with the ``OPLtpaToken2``
    cookie, that cookie is sufficient for subsequent API requests.

    Args:
        base_url:   OpenPages base URL, e.g. ``https://host/openpages``
        username:   OpenPages username (or email)
        password:   OpenPages password
        ssl_verify: Whether to verify SSL certificates

    Returns:
        Dict of session cookies ready to send as ``Cookie:`` header

    Raises:
        RuntimeError: If any step of the login flow fails
    """
    base = base_url.rstrip("/")
    headers_base = {
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "User-Agent": "GRC-MCP-Server/1.0",
    }

    async with httpx.AsyncClient(verify=ssl_verify, follow_redirects=False) as client:
        # ── Step 1: GET /logon.jsp to obtain initial OPJSESSIONID ────────────
        try:
            r1 = await client.get(f"{base}/logon.jsp", headers=headers_base, timeout=30.0)
        except httpx.RequestError as e:
            raise RuntimeError(f"Failed to reach OpenPages login page: {e}") from e

        initial_session = r1.cookies.get("OPJSESSIONID")
        if not initial_session:
            # Try to parse from Set-Cookie header directly
            for hv in r1.headers.get_list("set-cookie"):
                if "OPJSESSIONID=" in hv:
                    initial_session = hv.split("OPJSESSIONID=")[1].split(";")[0]
                    break
        if not initial_session:
            raise RuntimeError(
                "GET /logon.jsp did not return an OPJSESSIONID cookie. "
                "The OpenPages instance may be unreachable or the URL is wrong."
            )
        logger.info("Step 1/2: obtained initial OPJSESSIONID from /logon.jsp")

        # ── Step 2: POST /j_security_check with credentials ──────────────────
        try:
            r2 = await client.post(
                f"{base}/j_security_check",
                headers={**headers_base, "Content-Type": "application/x-www-form-urlencoded",
                          "Cookie": f"OPJSESSIONID={initial_session}"},
                data={"j_username": username, "j_password": password},
                timeout=30.0,
            )
        except httpx.RequestError as e:
            raise RuntimeError(f"Failed to POST credentials to /j_security_check: {e}") from e

        if r2.status_code not in (302, 200):
            raise RuntimeError(
                f"Login POST returned unexpected status {r2.status_code}. "
                "Check OPENPAGES_USERNAME and OPENPAGES_PASSWORD."
            )

        # A 302 to /openpages/ means success; a redirect back to logon.jsp means bad credentials
        location = r2.headers.get("location", "")
        if "logon.jsp" in location or ("logon" in location and r2.status_code == 302):
            raise RuntimeError(
                "Login failed: credentials were rejected (redirected back to login page). "
                "Check OPENPAGES_USERNAME and OPENPAGES_PASSWORD."
            )

        ltpa_token = r2.cookies.get("OPLtpaToken2")
        if not ltpa_token:
            for hv in r2.headers.get_list("set-cookie"):
                if "OPLtpaToken2=" in hv:
                    ltpa_token = hv.split("OPLtpaToken2=")[1].split(";")[0]
                    break
        if not ltpa_token:
            raise RuntimeError(
                "Login POST did not return OPLtpaToken2. "
                "The server may have rejected the credentials or the login form changed."
            )
        logger.info("Step 2/2: received OPLtpaToken2 after credential POST")

        return {
            "OPLtpaToken2": ltpa_token,
        }
