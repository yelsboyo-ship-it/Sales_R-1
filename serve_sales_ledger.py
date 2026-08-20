import json
import logging
import os
import socket
import threading
import time
import uuid
import urllib.error
import urllib.request
from collections import deque
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse
from urllib.parse import unquote


def create_http_server(host: str, port: int, handler: type[SimpleHTTPRequestHandler]) -> ThreadingHTTPServer:
    try:
        return ThreadingHTTPServer((host, port), handler)
    except Exception:
        log_event('warning', 'Requested port is unavailable; retrying with an available port', host=host, port=port)
        return ThreadingHTTPServer((host, 0), handler)

ROOT = Path(__file__).resolve().parent
ENV_PATH = ROOT / '.env'
SERVICE_NAME = 'Onestop veggies ltd'
API_VERSION = 'v1'
REQUEST_TIMEOUT = 10
RATE_LIMIT_WINDOW_SECONDS = 60
RATE_LIMIT_MAX_REQUESTS = 60

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s',
)

SENTRY_DSN = os.environ.get('SENTRY_DSN', '').strip()
ALERT_WEBHOOK_URL = os.environ.get('ALERT_WEBHOOK_URL', '').strip()
MONITORING_EMAIL = os.environ.get('MONITORING_EMAIL', '').strip()

try:
    import sentry_sdk  # type: ignore[import]
except ImportError:
    sentry_sdk = None

if sentry_sdk and SENTRY_DSN:
    sentry_sdk.init(dsn=SENTRY_DSN, environment=os.environ.get('ENVIRONMENT', 'development'))

START_TIME = time.time()
REQUEST_COUNTERS: dict[str, int] = {
    'total': 0,
    'success': 0,
    'client_error': 0,
    'server_error': 0,
    'rate_limited': 0,
}

_rate_limit_store: dict[str, deque[float]] = {}
_rate_limit_lock = threading.Lock()


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding='utf-8').splitlines():
        line = raw_line.strip()
        if not line or line.startswith('#') or '=' not in line:
            continue
        key, value = line.split('=', 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


ENV_VALUES = parse_env(ENV_PATH)


def log_event(level: str, message: str, **fields) -> None:
    payload = {
        'service': SERVICE_NAME,
        'version': API_VERSION,
        'timestamp': int(time.time()),
        'level': level,
        'message': message,
        'component': 'serve_sales_ledger',
        'trace_id': str(uuid.uuid4()),
        **fields,
    }
    text = json.dumps(payload, ensure_ascii=False)
    if level == 'info':
        logging.info(text)
    elif level == 'warning':
        logging.warning(text)
    elif level == 'error':
        logging.error(text)
    else:
        logging.debug(text)


def send_alert(subject: str, body: str) -> None:
    if ALERT_WEBHOOK_URL:
        try:
            req = urllib.request.Request(
                ALERT_WEBHOOK_URL,
                data=json.dumps({'subject': subject, 'body': body}).encode('utf-8'),
                headers={'Content-Type': 'application/json'},
                method='POST',
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                log_event('info', 'Sent alert webhook', alert_status=response.status)
        except Exception as exc:
            log_event('warning', 'Failed to send alert webhook', exception=str(exc))

    if MONITORING_EMAIL:
        log_event('info', 'Monitoring email is configured but email notifications are not implemented', email=MONITORING_EMAIL)


def build_supabase_config(env_values: dict[str, str] | None = None) -> dict[str, str]:
    values = dict(ENV_VALUES if env_values is None else env_values)
    if env_values is None:
        values.update({
            'SUPA_URL': os.environ.get('SUPA_URL', values.get('SUPA_URL', '')),
            'SUPA_KEY': os.environ.get('SUPA_KEY', values.get('SUPA_KEY', '')),
        })
    return {
        'SUPA_URL': (values.get('SUPA_URL') or '').strip(),
        'SUPA_KEY': (values.get('SUPA_KEY') or '').strip(),
    }


def inject_supabase_env(html: str, config: dict[str, str]) -> str:
    injection = (
        '<script>window.__SUPABASE_ENV__ = '
        + json.dumps(config)
        + ';</script>'
    )
    script_tag = '<script'
    if script_tag in html:
        position = html.index(script_tag)
        return html[:position] + injection + '\n' + html[position:]
    if '</head>' in html:
        return html.replace('</head>', injection + '\n</head>', 1)
    if '</body>' in html:
        return html.replace('</body>', injection + '\n</body>', 1)
    return injection + html


def is_rate_allowed(client_id: str) -> bool:
    now = time.monotonic()
    with _rate_limit_lock:
        queue = _rate_limit_store.setdefault(client_id, deque())
        while queue and now - queue[0] > RATE_LIMIT_WINDOW_SECONDS:
            queue.popleft()
        if len(queue) >= RATE_LIMIT_MAX_REQUESTS:
            return False
        queue.append(now)
        return True


def reset_rate_limits() -> None:
    with _rate_limit_lock:
        _rate_limit_store.clear()


def collect_metrics() -> dict[str, object]:
    uptime_seconds = int(time.time() - START_TIME)
    return {
        'service': SERVICE_NAME,
        'version': API_VERSION,
        'uptime_seconds': uptime_seconds,
        'request_counts': REQUEST_COUNTERS.copy(),
        'hostname': socket.gethostname(),
        'timestamp': int(time.time()),
    }


def json_response(handler: SimpleHTTPRequestHandler, payload: dict, status: int = 200) -> None:
    body = json.dumps(payload, ensure_ascii=False).encode('utf-8')
    handler.send_response(status)
    handler.send_header('Content-Type', 'application/json; charset=utf-8')
    handler.send_header('Content-Length', str(len(body)))
    handler.send_header('X-Service-Name', SERVICE_NAME)
    handler.send_header('X-API-Version', API_VERSION)
    handler.send_header('X-Request-ID', getattr(handler, 'request_id', 'unknown'))
    handler.end_headers()
    handler.wfile.write(body)


def json_error(handler: SimpleHTTPRequestHandler, status: int, code: str, message: str, details: dict | None = None) -> None:
    payload: dict = {
        'error': {
            'service': SERVICE_NAME,
            'code': code,
            'message': message,
        }
    }
    if details:
        payload['error']['details'] = details
    log_event('error', 'API error response generated', status=status, code=code, message=message, details=details or {})
    if sentry_sdk:
        sentry_sdk.capture_message(f'{code}: {message}', level='error')
    json_response(handler, payload, status)


def validate_echo_query(query: dict[str, list[str]]) -> tuple[str, str]:
    if 'message' not in query:
        return 'pong', 'pong'

    messages = query.get('message', [])
    if not messages:
        return 'pong', 'pong'

    message = messages[0].strip()
    if len(message) > 256:
        raise ValueError('message must be 256 characters or fewer')
    return message, message


class SalesLedgerHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def setup(self):
        super().setup()
        try:
            self.request.settimeout(REQUEST_TIMEOUT)
        except (AttributeError, OSError):
            pass

    def handle(self):
        self.request_id = str(uuid.uuid4())
        super().handle()

    def end_headers(self):
        environment = os.environ.get('ENVIRONMENT', 'development').strip().lower()
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'strict-origin-when-cross-origin')
        self.send_header('Permissions-Policy', 'camera=(), microphone=(), payment=(), usb=()')
        self.send_header(
            'Content-Security-Policy',
            "default-src 'self'; "
            "base-uri 'self'; object-src 'none'; frame-ancestors 'none'; "
            "script-src 'self' 'unsafe-inline' https://cdn.jsdelivr.net; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
            "font-src 'self' https://fonts.gstatic.com; "
            "img-src 'self' data: blob: https:; "
            "connect-src 'self' https://*.supabase.co https://formspree.io; "
            "frame-src https://maps.google.com https://www.google.com https://*.supabase.co; "
            "form-action 'self' https://formspree.io"
        )
        if environment == 'production':
            self.send_header('Strict-Transport-Security', 'max-age=31536000; includeSubDomains')
        super().end_headers()

    @staticmethod
    def is_public_asset_path(path: str) -> bool:
        decoded_path = unquote(path)
        if '..' in decoded_path or '\\' in decoded_path:
            return False
        blocked_suffixes = ('.sql', '.py', '.env', '.log', '.sqlite', '.sqlite3', '.bak', '.map')
        blocked_names = ('index.backup.html',)
        path_name = Path(decoded_path).name.lower()
        if path_name in blocked_names or path_name.endswith(blocked_suffixes):
            return False
        if decoded_path in ('/', '/sales-ledger.html', '/index.html', '/config.js'):
            return True
        return decoded_path.startswith('/Onestop_Veggies/')

    def do_GET(self):
        REQUEST_COUNTERS['total'] += 1
        client_id = self.client_address[0] if self.client_address else 'unknown'
        self.request_id = getattr(self, 'request_id', str(uuid.uuid4()))
        log_event('info', 'Incoming request', method='GET', path=self.path, client_id=client_id, request_id=self.request_id)

        if not is_rate_allowed(client_id):
            REQUEST_COUNTERS['rate_limited'] += 1
            log_event('warning', 'Rate limit exceeded', client_id=client_id)
            return json_error(self, 429, 'rate_limited', 'Too many requests. Try again later.')

        parsed = urlparse(self.path)
        try:
            if not self.is_public_asset_path(parsed.path) and not parsed.path.startswith(f'/api/{API_VERSION}/') and parsed.path not in ('/health',):
                REQUEST_COUNTERS['client_error'] += 1
                return json_error(self, 404, 'not_found', 'Not found.')
            if parsed.path in ('/', '/sales-ledger.html'):
                response = self.serve_sales_ledger()
            elif parsed.path in ('/Onestop_Veggies/index.html', '/Onestop_Veggies', '/Onestop_Veggies/'):
                response = self.serve_storefront()
            elif parsed.path == '/health' or parsed.path == f'/api/{API_VERSION}/health':
                response = self.serve_health()
            elif parsed.path == f'/api/{API_VERSION}/echo':
                response = self.serve_echo(parse_qs(parsed.query))
            elif parsed.path == f'/api/{API_VERSION}/metrics':
                response = self.serve_metrics()
            elif parsed.path == f'/api/{API_VERSION}/ready':
                response = self.serve_readiness()
            else:
                response = super().do_GET()
            REQUEST_COUNTERS['success'] += 1
            return response
        except Exception as exc:
            REQUEST_COUNTERS['server_error'] += 1
            log_event('error', 'Unhandled exception in request handling', exception=str(exc), path=self.path, client_id=client_id)
            if sentry_sdk:
                sentry_sdk.capture_exception(exc)
            send_alert('Critical server failure', f'Unhandled exception: {exc} on path {self.path}')
            return json_error(self, 500, 'internal_server_error', 'An unexpected error occurred.')

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path.startswith(f'/api/{API_VERSION}/'):
            REQUEST_COUNTERS['client_error'] += 1
            return json_error(self, 405, 'method_not_allowed', 'POST is not supported for this API endpoint.')
        return super().do_POST()

    def serve_sales_ledger(self) -> None:
        html_path = ROOT / 'sales-ledger.html'
        html = html_path.read_text(encoding='utf-8')
        html = inject_supabase_env(html, build_supabase_config())
        body = html.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_storefront(self) -> None:
        html_path = ROOT / 'Onestop_Veggies' / 'index.html'
        html = html_path.read_text(encoding='utf-8')
        html = inject_supabase_env(html, build_supabase_config())
        body = html.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_health(self) -> None:
        hostname = socket.gethostname()
        payload = {
            'status': 'ok',
            'service': SERVICE_NAME,
            'version': API_VERSION,
            'hostname': hostname,
            'timestamp': int(time.time()),
        }
        log_event('info', 'Health check passed', path=self.path, hostname=hostname)
        json_response(self, payload)

    def serve_metrics(self) -> None:
        metrics = collect_metrics()
        log_event('info', 'Metrics requested', path=self.path)
        json_response(self, metrics)

    def serve_readiness(self) -> None:
        payload = {
            'status': 'ready',
            'service': SERVICE_NAME,
            'version': API_VERSION,
            'hostname': socket.gethostname(),
            'timestamp': int(time.time()),
        }
        log_event('info', 'Readiness check passed', path=self.path)
        json_response(self, payload)

    def serve_echo(self, query: dict[str, list[str]]) -> None:
        try:
            _, message = validate_echo_query(query)
        except ValueError as exc:
            REQUEST_COUNTERS['client_error'] += 1
            return json_error(self, 400, 'invalid_request', str(exc))
        payload = {
            'service': SERVICE_NAME,
            'version': API_VERSION,
            'echo': message,
        }
        log_event('info', 'Echo request served', echo=message)
        json_response(self, payload)

    def log_message(self, format: str, *args) -> None:
        message = format % args
        log_event('info', 'HTTP access log', client=self.address_string(), timestamp=self.log_date_time_string(), details=message)


if __name__ == '__main__':
    host = os.environ.get('HOST', '0.0.0.0')
    port = int(os.environ.get('PORT', '8000'))
    with create_http_server(host, port, SalesLedgerHandler) as httpd:
        actual_port = httpd.server_address[1]
        display_host = host if host != '0.0.0.0' else '0.0.0.0'
        print(f'Serving sales ledger at http://{display_host}:{actual_port}/sales-ledger.html')
        print(f'Also available at http://127.0.0.1:{actual_port}/sales-ledger.html')
        print('Use your machine IP address, for example http://192.168.x.x:8000/sales-ledger.html, if you want to share it on your network.')
        log_event('info', 'Service startup', host=host, port=actual_port)
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            log_event('info', 'Service shutdown requested', host=host, port=actual_port)
            print('\nServer stopped.')
