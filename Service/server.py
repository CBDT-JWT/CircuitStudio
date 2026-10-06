"""Private email download registry. Run behind nginx, bound to loopback only."""
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import time

from flask import Flask, Response, abort, jsonify, request, send_from_directory


def create_app(settings=None):
    app = Flask(__name__)
    app.config.update(
        MAX_CONTENT_LENGTH=2048,
        CONTACT_DB=os.environ.get('CS_CONTACT_DB', '/tmp/circuitstudio-service/downloads.sqlite3'),
        RELEASE_DIR=os.environ.get('CS_RELEASE_DIR', '/tmp/circuitstudio-service/releases'),
        SITE_ORIGIN=os.environ.get('CS_SITE_ORIGIN', 'http://127.0.0.1:4173'),
        RATE_SALT=os.environ.get('CS_RATE_SALT', secrets.token_hex(32)),
        TOKEN_LIFETIME=3600,
        REQUESTS_PER_HOUR=30,
        WEBSITE_ROOT=os.environ.get('CS_WEBSITE_ROOT'),
    )
    if settings:
        app.config.update(settings)
    database = Path(app.config['CONTACT_DB'])
    database.parent.mkdir(parents=True, exist_ok=True)
    with closing(sqlite3.connect(database)) as connection:
        connection.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS contacts (
                id INTEGER PRIMARY KEY,
                email TEXT NOT NULL UNIQUE,
                created_at TEXT NOT NULL,
                first_download_at TEXT,
                last_download_at TEXT,
                last_version TEXT
            );
            CREATE TABLE IF NOT EXISTS tokens (
                digest TEXT PRIMARY KEY,
                contact_id INTEGER NOT NULL REFERENCES contacts(id),
                filename TEXT NOT NULL,
                version TEXT NOT NULL,
                expires_at REAL NOT NULL,
                redeemed_at TEXT
            );
            CREATE TABLE IF NOT EXISTS rate_events (
                source_hash TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            CREATE INDEX IF NOT EXISTS rate_sources ON rate_events(source_hash, created_at);
        ''')
        connection.commit()
    database.chmod(0o600)

    def connect():
        connection = sqlite3.connect(database, timeout=20)
        connection.row_factory = sqlite3.Row
        connection.execute('PRAGMA foreign_keys=ON')
        return connection

    def release():
        directory = Path(app.config['RELEASE_DIR']).resolve()
        metadata = json.loads((directory / 'release.json').read_text())
        name = metadata['file']
        if not re.fullmatch(r'CircuitStudio-[0-9A-Za-z.+-]+-universal\.dmg', name):
            raise ValueError('Invalid release filename')
        archive = directory / name
        if not archive.is_file() or archive.stat().st_size != metadata['bytes']:
            raise ValueError('The current release is unavailable')
        return metadata, archive

    @app.after_request
    def private_cache(response):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        return response

    @app.get('/api/stats')
    def stats():
        with closing(connect()) as connection:
            count = connection.execute('SELECT COUNT(*) FROM contacts WHERE first_download_at IS NOT NULL').fetchone()[0]
        try:
            metadata, _ = release()
        except (OSError, ValueError, KeyError):
            return jsonify(error='安装包暂时不可用，请稍后再试。'), 503
        return jsonify(downloads=count, release=metadata)

    @app.post('/api/request-download')
    def request_download():
        if request.headers.get('Origin') not in app.config['SITE_ORIGIN'].split(','):
            return jsonify(error='请从官网下载页面提交。'), 403
        if not request.is_json:
            return jsonify(error='请求格式无效。'), 415
        body = request.get_json(silent=True)
        if not isinstance(body, dict):
            return jsonify(error='请求格式无效。'), 400
        email = body.get('email')
        if not isinstance(email, str):
            return jsonify(error='请填写有效的邮箱地址。'), 400
        email = email.strip().lower()
        if len(email) > 254 or not re.fullmatch(r'[^\s@<>(),;:"\\]+@[^\s@<>(),;:"\\]+\.[^\s@<>(),;:"\\]+', email):
            return jsonify(error='请填写有效的邮箱地址。'), 400
        if body.get('company'):
            return jsonify(error='请求未通过，请稍后再试。'), 400
        try:
            metadata, _ = release()
        except (OSError, ValueError, KeyError):
            return jsonify(error='安装包暂时不可用，请稍后再试。'), 503
        now = time.time()
        stamp = datetime.now(timezone.utc).isoformat()
        source = request.headers.get('X-Real-IP', request.remote_addr or 'unknown')
        source_hash = hmac.new(app.config['RATE_SALT'].encode(), source.encode(), hashlib.sha256).hexdigest()
        token = secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        with closing(connect()) as connection:
            connection.execute('BEGIN IMMEDIATE')
            connection.execute('DELETE FROM rate_events WHERE created_at < ?', (now - 3600,))
            connection.execute('DELETE FROM tokens WHERE expires_at < ?', (now,))
            used = connection.execute('SELECT COUNT(*) FROM rate_events WHERE source_hash=?', (source_hash,)).fetchone()[0]
            if used >= app.config['REQUESTS_PER_HOUR']:
                connection.rollback()
                return jsonify(error='请求较多，请稍后再试。'), 429
            connection.execute('INSERT INTO rate_events VALUES (?,?)', (source_hash, now))
            connection.execute('INSERT OR IGNORE INTO contacts(email,created_at) VALUES (?,?)', (email, stamp))
            contact = connection.execute('SELECT id FROM contacts WHERE email=?', (email,)).fetchone()[0]
            connection.execute('INSERT INTO tokens(digest,contact_id,filename,version,expires_at) VALUES (?,?,?,?,?)',
                               (digest, contact, metadata['file'], metadata['version'], now + app.config['TOKEN_LIFETIME']))
            connection.commit()
        return jsonify(downloadURL='api/download/' + token, version=metadata['version'])

    @app.get('/api/download/<token>')
    def download(token):
        if not re.fullmatch(r'[A-Za-z0-9_-]{43}', token):
            return jsonify(error='下载链接无效。'), 404
        digest = hashlib.sha256(token.encode()).hexdigest()
        with closing(connect()) as connection:
            issued = connection.execute('SELECT * FROM tokens WHERE digest=? AND expires_at>?', (digest, time.time())).fetchone()
        if issued is None:
            return jsonify(error='下载链接已过期，请返回官网重新领取。'), 410
        archive = Path(app.config['RELEASE_DIR']) / issued['filename']
        if not archive.is_file():
            return jsonify(error='安装包暂时不可用，请重新领取。'), 503

        def content():
            with archive.open('rb') as stream:
                while chunk := stream.read(256 * 1024):
                    yield chunk
            # This is reached only when the full response has been consumed.
            stamp = datetime.now(timezone.utc).isoformat()
            with closing(connect()) as connection:
                connection.execute('UPDATE contacts SET first_download_at=COALESCE(first_download_at,?), last_download_at=?, last_version=? WHERE id=?',
                                   (stamp, stamp, issued['version'], issued['contact_id']))
                connection.execute('UPDATE tokens SET redeemed_at=COALESCE(redeemed_at,?) WHERE digest=?', (stamp, digest))
                connection.commit()

        response = Response(content(), mimetype='application/x-apple-diskimage')
        response.headers['Content-Length'] = str(archive.stat().st_size)
        response.headers['Content-Disposition'] = f'attachment; filename="{issued["filename"]}"'
        response.headers['X-Accel-Buffering'] = 'no'
        return response

    @app.errorhandler(413)
    def too_large(_):
        return jsonify(error='请求内容过长。'), 413

    if app.config['WEBSITE_ROOT']:
        @app.get('/')
        @app.get('/<path:filename>')
        def preview(filename='index.html'):
            if filename.endswith('.dmg') or filename.startswith('api/'):
                abort(404)
            return send_from_directory(app.config['WEBSITE_ROOT'], filename)

    return app
