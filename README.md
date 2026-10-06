# Sungira — shared group collections (version 4)

This package upgrades the original browser ledger to a shared application backed by Supabase and Netlify Functions. It contains account registration, email confirmation, sign-in, password recovery, shared group access, public progress pages, treasurer payment review, optional verified PayChangu checkout, contribution/expense ledgers and expenditure reports.

The package is implemented and locally tested, but is NOT connected to a live Supabase project, email service or PayChangu account, and has NOT been deployed. Do not announce live registration or payment collection until setup and live checks below are complete.

## Update your existing live Sungira site

Your existing accounts and collection records are retained. In Supabase SQL Editor run `database/payments.sql`, then `database/upgrade-v4.sql`, in that order. Then replace your existing Netlify repository files with this package and redeploy. Keep your existing environment keys. Do not rerun `setup.sql` after this upgrade: it installs the older RPC function.

Open each collection and use **Settings & public view** to enable member viewing, then **Member viewing link** to copy or share its new unique link. Old UUID-only links must be replaced. Members open the link without registering. The owner can replace a viewing link, invalidating the previous one. Anyone holding an enabled link can view the public summary; public names require consent. Borrower details, contacts, payment evidence and private plan titles stay in officer views.

## Version 4 workflows

Officers register and sign in. Ordinary contributors do not need accounts: they receive the viewing link, pay through the group's published instructions, and contact the officer with their payment reference. Officers record and verify contributions. Public totals refresh about every 10 seconds while the page is open, with a manual refresh button.

**Investment savings:** record actual cash invested, review dates, cash received and original capital cost released. Reports distinguish available cash, investment capital at cost, realised gain/loss and total recorded assets. These records do not execute investments or automatically divide profits among members.

**Member lending:** select a contributor, record principal, agreed interest rate, term and first instalment date. Choose a flat percentage for the whole term or simple monthly interest on original principal. The app creates a monthly schedule, tracks overdue amounts, separates principal and interest repayments, and records approved write-offs/waivers. Expected interest is not counted as cash or an asset. There is no compounding, automatic penalty or automatic early-settlement discount. Borrower identities and agreements remain private to authorised officers.

Five further uses are implemented through **Plans & delivery**:

| Collection type | Workflow |
| --- | --- |
| Emergency welfare fund | Private assistance case, approved budget, due date, linked payment and completion |
| School-fee support | Private learner/school/term note, planned fees, deadline, linked expense and completion |
| Community project | Milestone budget, due date, actual spending and delivery status |
| Bulk purchasing | Quantity × unit cost, optional order owner, supplier expense and delivery status |
| Event / trip fund | Places or bookings × unit cost, deadlines, actual spending and completion |

Each plan can have an optional member-facing label; its private title stays hidden. Linked expenditure cannot exceed the remaining planned budget or available cash. Completion is marked by an officer. Officer reports and CSV downloads include savings allocations and plans. Corrections retain an audit history.

## One-time setup for the organiser / technical helper

Ordinary users do not perform any of these setup steps.

1. Create a Supabase project. Open its SQL Editor and run `database/setup.sql`, then `database/payments.sql`, then `database/upgrade-v4.sql`. Use a fresh project or check the table names before running them. Both scripts can be rerun without deleting collection records.
2. In Supabase Authentication, enable email/password sign-up and KEEP email confirmation enabled. Configure custom SMTP for confirmation and password-reset emails to ordinary users. Supabase's default email sender is restricted to project team addresses; it is not suitable for public registration. See https://supabase.com/docs/guides/auth/auth-smtp .
3. Extract the ZIP. Deploy the project through a connected Git repository in Netlify, or through the Netlify CLI. **Dragging the folder into Netlify Drop is insufficient for this version because server Functions must be deployed.** Netlify reads `netlify.toml`; build command is `node build.cjs`, publish directory is `public`, function directory is `netlify/functions`. There are no runtime npm dependencies.
4. In the Netlify site's environment settings, add these values for the Functions scope:

| Variable | Value | Public? |
| --- | --- | --- |
| `SUPABASE_URL` | Project URL, e.g. `https://PROJECT.supabase.co` | Yes |
| `SUPABASE_ANON_KEY` | Supabase legacy anon/public key | Yes |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase legacy service-role secret key | NO — server only |
| `SEED_OWNER_EMAIL` | The email Chifundo will use to create the church collection | Not sent to the browser |

Never put a service-role key or merchant secret into HTML/JavaScript, Git or a public message. The config endpoint exposes only the public URL/key and feature availability.

5. In Supabase Authentication URL Configuration, set Site URL to the final Netlify HTTPS URL, and add that exact URL with a trailing slash to the allowed redirect URLs. Confirmation and reset links return there. Use standard confirmation templates with `ConfirmationURL` so the direct REST authentication flow can complete.
6. Redeploy after changing environment settings. Open the site. Create the designated organiser account and confirm its email. Sign in. Click **Create with the church list** once to create **Charles Luanga Paper Sunday**. Set the actual collection deadline; none was supplied by the photograph. The prepared list button is reserved for `SEED_OWNER_EMAIL` to prevent unrelated users retrieving church names.
7. Create a second account from a different email. From the owner account, open **Group access**, add that email as Treasurer or read-only Viewer, then sign in with the second account to verify sharing. Account-access grants do not automatically send invitation emails; send the site link yourself.
8. Open **Settings & public view** and publish the collection if desired. Copy its public link via **Member viewing link**. Public visitors do not need accounts. Publishing names requires each contributor's consent flag under **People → Edit**; names are private by default.

## Charles Luanga Paper Sunday list

The attachment is headed “2026 MLOZO WA KOLONA ST CHARLES LWANGWA OCTOBER” and contains a church programme, not a financial statement. We copied the names, preserving family/couple entries. No payment amounts, pledges, deadlines or receipts were inferred from it.

There are 30 dated rows (2–31 October), with “Bambo ndi Mayi Kanike” repeated on 7 and 21 October. The prepared collection therefore has **29 distinct contributor entries**, with zero recorded pledges and no payments. R Kanagwa and D Kanagwa remain separate. `Charles-Luanga-Paper-Sunday-names.csv` contains the names for review. Confirm the spellings and the duplicate before real use. The supplied title “Charles Luanga Paper Sunday” is retained; the programme's church spelling differs.

## Accounts and access

| Role | Allowed work |
| --- | --- |
| Owner | Treasurer work, settings, account access and viewing-link replacement |
| Treasurer | Contributors, payment review, expenses, loans, investments, plans and reports |
| Viewer | Read-only access to private officer records and reports |
| Link holder | Public collection totals, consented contributor names, expenditure summary and explicitly published plan labels |

Only grant accounts to responsible officers or reviewers. Existing Member accounts become read-only; new Member grants are disabled. Account-access grants do not send invitations automatically. Public link holders cannot write to the ledger. Contribution names are ledger records, not user accounts.

## Optional PayChangu provider verification

Manual Airtel Money, TNM Mpamba, bank and cash records use **treasurer confirmation**. Sungira cannot query arbitrary external wallet or bank references. **Provider verified** is used only for successful PayChangu checkout payments verified through PayChangu's server API.

This package binds ONE merchant account to ONE designated collection. Other groups continue using their own payment instructions and treasurer confirmation. It does not send every group's payments to a central account or implement payouts. To enable independent online checkout for many groups, add PayChangu Connect merchant onboarding and secure per-group credentials. Do not reuse one merchant binding indiscriminately.

After approving the intended merchant destination, set these Netlify Functions environment variables:

| Variable | Value |
| --- | --- |
| `PAYCHANGU_SECRET_KEY` | Live merchant secret key, server only |
| `PAYCHANGU_COLLECTION_ID` | The UUID from the intended collection's public link (`?collection=UUID`) |
| `PAYCHANGU_MERCHANT_NAME` | Clear name of the actual recipient shown before payment |
| `PAYCHANGU_WEBHOOK_SECRET` | Webhook signing secret from the merchant dashboard |

Netlify supplies `URL`; it must be the final HTTPS site URL. Configure the merchant webhook URL as `https://YOUR-SITE/.netlify/functions/payment-webhook`, using the same signing secret. Redeploy. **Pay online** now appears only for the bound collection and eligible signed-in group accounts.

Checkout reserves a unique reference and the contributor/expected amount on the server. Verification re-queries PayChangu and requires matching reference, successful status, exact amount, MWK currency, and live mode. Test-mode results never credit the live ledger. Valid signed webhook notifications are independently re-verified before crediting. Duplicate callbacks/webhooks cannot credit twice. A payment can also be checked from its pending ledger row by the reporting account, or on return from checkout. Redirect query parameters alone never confirm a payment.

Provider charges are recorded as a separate confirmed expense. The contribution is gross; the net ledger balance subtracts charges. Provider-held funds are not necessarily already settled to the group's bank account; reconcile against actual cash, wallet and merchant statements. Checkout started while open can settle after closing: the system records the incoming payment and reopens the collection for reconciliation.

Documentation used:
- https://developer.paychangu.com/docs/standard-checkout
- https://developer.paychangu.com/docs/transaction-verification
- https://developer.paychangu.com/docs/webhooks
- https://developer.paychangu.com/docs/paychangu-connect

## Spending, reporting and corrections

Expenses require recipient, purpose, amount, date and category. They cannot exceed the confirmed ledger balance; the database serialises changes per collection to prevent simultaneous overspending. Banki mkhonde has a rotation schedule and separate payout entries. Moving a turn never moves money. Fixed-term loan interest and repayment schedules are included. Automatic annual share-out allocation is not included; use a separate collection for each period/round.

At the deadline, Reports automatically becomes an end-of-period report. It shows confirmed contributions by person, expenditure detail/category totals, outstanding pledges, pending amounts excluded from cash totals and closing balance. Late entries assigned to the collection are included and disclosed. Print/save PDF or download HTML/CSV. Public pages offer a privacy-limited expenditure summary and printable view.

Close the collection after reconciling. Closing locks contributor/financial entries until authorised reopening; owner publishing/settings remain editable. Corrections use reasoned voids, not deletion. An income void that would leave a negative balance is rejected. Server-generated activity records cannot be edited by group users; database administrators still control the database. This is not an independent audit.

## Existing device records

`local.html` retains the preceding device-only application with its existing `sungira.v2` local records, backup and restore. These do not automatically merge with the shared database. The shared ledger does not accept arbitrary JSON restoration, because that could bypass review and audit rules. Re-enter verified opening collection records through the normal workflow if migration is needed, and retain the original backup.

## Validation completed

- JavaScript syntax checks and SQL/PL/pgSQL parsing.
- PostgreSQL-engine tests (PGlite): schema creation, seed, permissions, pending/confirmed transitions, duplicate references, overspending, public consent/privacy, closing, provider mode/amount guards, charges, idempotency, revocation and blocked direct authenticated table/RPC access.
- DOM integration (JSDOM) with that database: sign-in (mock Auth), seeded collection, people, contribution/review, expense/report totals, access grant, publishing, consent, public page and closing.
- Function tests with mocked external services: verified identity, secret isolation, provider status/amount/mode checks, webhook signature and tampering rejection.
- Static build excludes SQL, source function files and the private seed CSV from the public assets.

Live Supabase Auth/SMTP, live PayChangu checkout/webhook delivery, Netlify deployment and browser visual/mobile testing are not yet verified. Chromium installation was attempted but the browser download was unavailable. Run the live checks before inviting users or collecting money. Ensure database backups are enabled in your selected Supabase plan, and periodically export group reports.

## Version 4 validation

PostgreSQL-engine checks cover viewing-link tokens and replacement, officer-only writes, cash/capital separation, loan schedules and allocations, retry idempotency, investment profits/losses, write-offs, correction reversals, all five plan workflows and a non-destructive repeat migration. DOM integration checks cover officer sign-in, the church list, contribution review, reporting and accountless token-based public viewing. Authentication and payment-provider requests are mocked in local tests; live email, payment settlement and real-device layout need checks after deployment.
