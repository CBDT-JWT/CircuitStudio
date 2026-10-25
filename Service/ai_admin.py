"""Private, CSRF-protected configuration UI and revocable relay access codes."""
from contextlib import closing, contextmanager
from pathlib import Path
import hashlib
import hmac
import secrets
import sqlite3
import time
from functools import wraps

from flask import request, session, redirect, url_for, render_template_string
from werkzeug.security import check_password_hash

SHELL = '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Circuit Studio · AI 后台</title>
<style>body{font:16px system-ui;background:#f6f7f8;color:#172026;max-width:780px;margin:50px auto;padding:0 24px}section{background:white;padding:24px;border-radius:12px;margin:18px 0}input,select,button{font:inherit;padding:10px;border:1px solid #ccd2d6;border-radius:6px;box-sizing:border-box}input{width:100%;margin:8px 0 14px}button{background:#176f66;color:white;cursor:pointer}label{display:block}small{color:#52616b}code{overflow-wrap:anywhere}table{width:100%;border-collapse:collapse}td,th{text-align:left;padding:10px 5px;border-bottom:1px solid #eee}a{color:#176f66}.error{color:#a42c25}</style>
<h1>Circuit Studio · AI 后台</h1>{{ content|safe }}</html>'''
LOGIN = '''<section><h2>管理员登录</h2><p>使用服务器上的管理员密码。</p>{% if error %}<p class="error">{{error}}</p>{% endif %}<form method="post"><input type="hidden" name="csrf" value="{{csrf}}"><label>管理员密码<input type="password" name="password" autocomplete="current-password" required maxlength="256"></label><button>登录</button></form></section>'''
ADMIN = '''<p>电路解读经你的服务器调用 DeepSeek。API Key 不会返回给 App 或浏览器。</p>
{% if notice %}<section>{{notice}}</section>{% endif %}
<section><h2>DeepSeek 配置</h2><p>状态：{{ '已配置' if configured else '等待填写 API Key' }}</p><form method="post" action="{{url_for('ai_admin_settings')}}"><input type="hidden" name="csrf" value="{{csrf}}"><label>新的 API Key<input type="password" name="api_key" autocomplete="off" placeholder="留空保留现有密钥" maxlength="256"></label><label>模型<select name="model">{% for name in ['deepseek-flash','deepseek-v4-pro'] %}<option {% if model == name %}selected{% endif %}>{{name}}</option>{% endfor %}</select></label><p><button>保存配置</button></p></form></section>
<section><h2>App 访问码</h2><p>给 App 填访问码即可解读电路；不要向用户分发 DeepSeek API Key。每个访问码每小时最多 30 次，可单独停用。</p>
{% if new_token %}<p>仅显示一次，请保存到 App 的“服务设置”：</p><code>{{new_token}}</code>{% endif %}
<form method="post" action="{{url_for('ai_admin_token')}}"><input type="hidden" name="csrf" value="{{csrf}}"><label>备注<input name="label" maxlength="80" required placeholder="例如：我的 Mac"></label><label>每月成功回答上限<input type="number" name="calls" value="200" min="1" max="10000" required></label><button>生成访问码</button></form>
<table><tr><th>备注</th><th>本月用量</th><th>操作</th></tr>{% for token in tokens %}<tr><td>{{token['label']}}</td><td>{{token['used']}} / {{token['calls']}}</td><td>{% if token['revoked'] %}已停用{% else %}<form method="post" action="{{url_for('ai_admin_revoke')}}"><input type="hidden" name="csrf" value="{{csrf}}"><input type="hidden" name="id" value="{{token['id']}}"><button>停用</button></form>{% endif %}</td></tr>{% endfor %}</table></section>
<form method="post" action="{{url_for('ai_admin_logout')}}"><input type="hidden" name="csrf" value="{{csrf}}"><button>退出登录</button></form>'''

class AIAdmin:
    def __init__(self, app, database, access_error):
        self.app, self.database, self.error = app, database, access_error
        with self.transaction() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS ai_settings (name TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS relay_tokens (id TEXT PRIMARY KEY, digest TEXT UNIQUE NOT NULL, label TEXT NOT NULL, calls INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS admin_attempts (address TEXT NOT NULL, created REAL NOT NULL);''')
            db.execute('INSERT OR IGNORE INTO ai_settings VALUES (?,?)',('session_secret',secrets.token_hex(32)))
            secret = db.execute('SELECT value FROM ai_settings WHERE name=?',('session_secret',)).fetchone()['value']
        app.secret_key = secret
        app.config.update(SESSION_COOKIE_NAME='cs_ai_admin',SESSION_COOKIE_HTTPONLY=True,SESSION_COOKIE_SAMESITE='Strict',SESSION_COOKIE_SECURE=not app.testing,PERMANENT_SESSION_LIFETIME=1800)
        self.register_routes()

    def connect(self):
        db = sqlite3.connect(self.database,timeout=20); db.row_factory = sqlite3.Row
        return db

    @contextmanager
    def transaction(self):
        with closing(self.connect()) as db:
            with db:
                yield db

    def provider_config(self):
        config = dict(self.app.config)
        with closing(self.connect()) as db:
            for row in db.execute('SELECT name,value FROM ai_settings WHERE name IN (?,?)',('provider_key','model')):
                config['DEEPSEEK_API_KEY' if row['name']=='provider_key' else 'DEEPSEEK_MODEL'] = row['value']
        return config

    def access(self, token):
        if not 32 <= len(token) <= 200: raise self.error('访问码无效。',401)
        with closing(self.connect()) as db:
            row = db.execute('SELECT * FROM relay_tokens WHERE digest=? AND revoked=0',(hashlib.sha256(token.encode()).hexdigest(),)).fetchone()
        if row is None: raise self.error('访问码无效或已停用。',401)
        return row['id'], time.strftime('%Y-%m',time.gmtime()), row['calls']

    def csrf(self):
        if 'csrf' not in session: session['csrf'] = secrets.token_urlsafe(32)
        return session['csrf']

    def validate_csrf(self):
        if not session.get('csrf') or not hmac.compare_digest(request.form.get('csrf',''),session['csrf']):
            raise self.error('页面已过期，请刷新后重试。',403)

    def authorized(self, fn):
        @wraps(fn)
        def wrapped(*args,**kwargs):
            if not session.get('admin'): return redirect(url_for('ai_admin_login'))
            if request.method == 'POST': self.validate_csrf()
            return fn(*args,**kwargs)
        return wrapped

    def page(self, template, **values):
        return render_template_string(SHELL,content=render_template_string(template,csrf=self.csrf(),**values))

    def dashboard(self, notice=None, new_token=None):
        config = self.provider_config()
        with closing(self.connect()) as db:
            tokens = db.execute('SELECT t.*,COALESCE(u.used,0) used FROM relay_tokens t LEFT JOIN usage u ON u.subject=t.id AND u.period=? ORDER BY t.rowid DESC',(time.strftime('%Y-%m',time.gmtime()),)).fetchall()
        return self.page(ADMIN,configured=bool(config['DEEPSEEK_API_KEY']),model=config.get('DEEPSEEK_MODEL','deepseek-flash'),tokens=tokens,notice=notice,new_token=new_token)

    def register_routes(self):
        app = self.app
        @app.route('/admin/login',methods=['GET','POST'])
        def ai_admin_login():
            error = None
            if request.method == 'POST':
                self.validate_csrf()
                address = hashlib.sha256((app.secret_key+(request.remote_addr or 'unknown')).encode()).hexdigest()
                with self.transaction() as db:
                    db.execute('DELETE FROM admin_attempts WHERE created<?',(time.time()-900,))
                    if db.execute('SELECT COUNT(*) FROM admin_attempts WHERE address=?',(address,)).fetchone()[0] >= 8:
                        raise self.error('登录尝试过多，请 15 分钟后重试。',429)
                    db.execute('INSERT INTO admin_attempts VALUES (?,?)',(address,time.time()))
                password = request.form.get('password','')
                digest = app.config.get('ADMIN_PASSWORD_HASH','')
                if digest and len(password)<=256 and check_password_hash(digest,password):
                    session.clear(); session['admin']=True; session.permanent=True; self.csrf()
                    return redirect(url_for('ai_admin'))
                error = '密码错误或管理员尚未配置。'
            return self.page(LOGIN,error=error)

        @app.get('/admin')
        @self.authorized
        def ai_admin(): return self.dashboard()

        @app.post('/admin/settings')
        @self.authorized
        def ai_admin_settings():
            key=request.form.get('api_key','').strip(); model=request.form.get('model','')
            if model not in ('deepseek-flash','deepseek-v4-pro') or (key and (not key.startswith('sk-') or len(key)>256 or any(c.isspace() for c in key))):
                raise self.error('请检查密钥和模型。',400)
            with self.transaction() as db:
                if key: db.execute('INSERT OR REPLACE INTO ai_settings VALUES (?,?)',('provider_key',key))
                db.execute('INSERT OR REPLACE INTO ai_settings VALUES (?,?)',('model',model))
            return redirect(url_for('ai_admin'))

        @app.post('/admin/tokens')
        @self.authorized
        def ai_admin_token():
            label=request.form.get('label','').strip()
            try: calls=int(request.form.get('calls',''))
            except ValueError: calls=0
            if not label or len(label)>80 or not 1<=calls<=10000: raise self.error('备注或次数无效。',400)
            token='cs_'+secrets.token_urlsafe(32)
            with self.transaction() as db:
                db.execute('INSERT INTO relay_tokens VALUES (?,?,?,?,0)',('relay-'+secrets.token_hex(12),hashlib.sha256(token.encode()).hexdigest(),label,calls))
            return self.dashboard(new_token=token)

        @app.post('/admin/tokens/revoke')
        @self.authorized
        def ai_admin_revoke():
            with self.transaction() as db: db.execute('UPDATE relay_tokens SET revoked=1 WHERE id=?',(request.form.get('id',''),))
            return redirect(url_for('ai_admin'))

        @app.post('/admin/logout')
        @self.authorized
        def ai_admin_logout(): session.clear(); return redirect(url_for('ai_admin_login'))
