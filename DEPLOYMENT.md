# Render deployment

This repository is deployed as one Python web service. It serves both applications and does not need a separate Node.js service.

## Production architecture

```text
Internet
   |
   v
Render Web Service (HTTPS + custom domain)
   |-- /                         public storefront
   |-- /sales-ledger.html        internal dashboard shell
   |-- /health                   Render health check
   |
   v
Supabase
   |-- Auth                      dashboard login and sessions
   |-- PostgreSQL                application data
   |-- RLS                       database authorization boundary
   `-- Storage                   receipts and approved file assets
```

Render serves the HTML, CSS, and JavaScript only. The browser connects to Supabase using the publishable/anon key; Supabase Auth and RLS enforce access to internal data. The dashboard URL is not a replacement for authentication: every protected table and function must remain protected by Supabase policies.

## File groups

- **Runtime:** `serve_sales_ledger.py` is the Render start point. `requirements.txt` contains the only optional package and `runtime.txt` pins the Python runtime.
- **Public storefront:** `Onestop_Veggies/index.html`, `Onestop_Veggies/script.js`, `Onestop_Veggies/styles.css`, and their local assets are available at `/`.
- **Sales system:** `sales-ledger.html` is available at `/sales-ledger.html` and is the authenticated staff interface.
- **Configuration:** `config.js` and `Onestop_Veggies/config.js` provide browser defaults. Production values are injected by the Python server from `SUPA_URL` and `SUPA_KEY`.
- **Database:** `supabase_schema.sql` is the base schema. The files named `migration_*.sql`, `rls_*.sql`, `sales_approval_workflow.sql`, `storage_deposit_confirmations.sql`, and `website_public_portal.sql` are database deployment scripts.
- **Verification:** `tests/` contains the Python regression tests. The `tmp/` folder is for local repair/check scripts and is not part of the deployment surface.
- **Render:** `render.yaml` defines the web service, health check, and environment variable prompts.

## 1. Prepare Supabase

1. Create or select a Supabase project.
2. Open **Project Settings > API** and copy the **Project URL** and the publishable/anon key. Never use a service-role key in this app.
3. In the Supabase SQL Editor, run `supabase_schema.sql` first.
4. Run the feature scripts in dependency order: security/profile scripts, bank-account scripts, sales confirmation/approval scripts, delivery scripts, stock-transfer scripts, then the public portal/storage scripts. Run each script only once unless it is explicitly written as an idempotent migration.
5. In **Authentication > URL Configuration**, add the final Render URL to **Site URL** and add the same URL plus any local development URL to **Redirect URLs**.
6. In **Storage**, create the buckets referenced by the schema/scripts and confirm their policies. Do not make private buckets public just to hide an application error.
7. Create at least one administrator or manager profile after the first user signs up. Confirm its `profiles.role` matches the role expected by the SQL policies.

## 2. Deploy on Render

### Blueprint deployment

1. Push this repository to GitHub or GitLab. Do not commit `.env` or any Supabase secret.
2. In Render, choose **New > Blueprint** and select the repository.
3. Render detects `render.yaml`. When prompted, enter:
   - `SUPA_URL`: the Supabase project URL.
   - `SUPA_KEY`: the Supabase publishable/anon key.
4. Deploy. Render supplies `PORT`; the service binds to `0.0.0.0` through the blueprint.

After the first successful deploy, add your custom domain in Render. Then replace the temporary `onrender.com` URL with the custom HTTPS URL in Supabase **Site URL** and **Redirect URLs**, and test login again.

### Manual web-service deployment

Use these values if creating the service manually:

- **Runtime:** Python 3
- **Build command:** `pip install -r requirements.txt`
- **Start command:** `python serve_sales_ledger.py`
- **Health check path:** `/health`
- **Environment:** `ENVIRONMENT=production`, `HOST=0.0.0.0`, `SUPA_URL=...`, `SUPA_KEY=...`

Do not set a fixed `PORT` on Render. Render assigns it at runtime.

## 3. Verify the live system

After deployment, check these URLs:

- `/health` returns JSON with `"status": "ok"`.
- `/` loads the public storefront and product availability.
- `/sales-ledger.html` loads the staff login.
- `/api/v1/ready` returns `"status": "ready"`.
- `/api/v1/echo?message=render-check` returns the echoed message.

Then exercise the real workflows with test records: sign in as an administrator, create/read produce, submit a sales record, approve it, verify the bank balance once, test delivery status transitions, and test stock transfer confirmation/cancellation. Check the browser console and Render logs for failed Supabase requests.

## Important production checks

- Supabase RLS and SQL functions are the authorization boundary. Keep the publishable/anon key in the browser, but never expose a service-role key or database password.
- The sales ledger is intentionally an authenticated application; verify unauthenticated users cannot read protected data through Supabase policies.
- A Render free instance can sleep and has ephemeral local storage. This app must keep durable data in Supabase; do not add file uploads or local databases without a persistent storage design.
- Configure a custom domain only after the Render URL works, then update Supabase Site URL and redirect URLs to the custom domain.
- For production monitoring, set `SENTRY_DSN` and optionally `ALERT_WEBHOOK_URL` in Render environment variables. Redeploy after changing environment variables.

## Local pre-deploy check

From the repository root:

```powershell
python -m unittest discover -s tests -p "test_*.py" -v
python serve_sales_ledger.py
```

In another terminal, request `http://127.0.0.1:8000/health`. Stop the server with `Ctrl+C`.
